defmodule WhoseJam.Game.Server do
  @moduledoc """
  The per-game runtime: one `GenServer` per active game, registered under its
  room code in `WhoseJam.Game.Registry` and supervised by
  `WhoseJam.Game.Supervisor` (a `DynamicSupervisor`).

  All runtime state (players, audience, assignments, submissions, votes, scores,
  phase) lives in this process and is discarded when it stops — nothing is
  persisted. The only database reads happen at `start_game` time, pulling the
  gameplay question pools via `WhoseJam.Content`.

  ## State machine

      :lobby
        └─ per sub-round:
             :answering ──▶ :playing
                              ├─ round :revealing  (listening delay: song plays, votes closed for vote_delay_s)
                              ├─ round :voting     (song keeps playing; clients guess)
                              └─ round :results    (submitter + deltas revealed)
             ...next sub-round or...
        └─ :finished

  ## Voting countdown

  `:voting` opens with no deadline. The `vote_timer_s` countdown starts at the
  first of: a majority of eligible voters (connected, not the submitter) have
  voted, the song ends, or a safety timeout. Once every eligible voter has
  voted the countdown drops to 5s (`@all_voted_countdown_s`) — never
  lengthening it.
  When the countdown hits zero the round moves to `:results`.

  Sub-rounds come from the theme's `style_sequence`. When
  `config.subrounds_enabled?` is false the sequence collapses into a *single*
  answering phase spanning every style, then a single playing phase over all
  resulting songs.

  ## Contracts

  Callers only ever touch this module through `WhoseJam.Game`. Events go in as
  `GenServer` calls; the resulting public state comes back out via
  `public_view/1` (and is broadcast on `"game:" <> code`). The public view is a
  plain map safe for every client — it never leaks who submitted the current
  song, anyone else's pending submissions, or vote choices before the reveal.
  The Spotify access token is exposed only through the host-scoped `:host_state`
  query.
  """

  use GenServer, restart: :temporary

  alias WhoseJam.Content
  alias WhoseJam.Game.{Binning, Config, Scoring}

  # --- capacity / timing constants -----------------------------------------

  @max_players 8
  @audience_soft_cap 20

  # Idle guards. Kept large so they never interfere with a live game or a test;
  # they exist so an abandoned/finished game eventually frees its process.
  @finished_shutdown_ms 5 * 60 * 1000
  @abandoned_ttl_ms 60 * 60 * 1000
  # Defensive ceiling on uncounted voting, in case the TV never reports the song
  # ending and nobody votes. Real clients call `song_ended/1` well before this.
  @voting_safety_extra_s 120
  # Once every eligible voter has voted the countdown drops to this (never
  # lengthening a shorter remaining countdown).
  @all_voted_countdown_s 5

  @guess_question_decoys 3

  # --- server state ---------------------------------------------------------

  defstruct code: nil,
            theme: nil,
            overrides: %{},
            # frozen at start_game; nil while in :lobby
            config: nil,
            spotify: nil,
            phase: :lobby,
            round_state: nil,
            # id => %{id, name, role, connected?}
            participants: %{},
            # join order (both roles)
            order: [],
            last_activity_ms: 0,
            # id => total score
            scores: %{},
            # style => [runtime_question]
            style_pools: %{},
            # [%{styles, assignments, questions_by_id}]
            subrounds: [],
            subround_index: 0,
            # answering scope
            submissions: %{},
            answer_deadline_ms: nil,
            answer_ref: nil,
            # playing scope
            rounds: [],
            round_index: 0,
            round: nil,
            # when votes open (end of the listening delay)
            votes_open_ms: nil,
            # voting countdown deadline; nil until the countdown starts
            vote_deadline_ms: nil,
            # in :voting, either the safety timer (before the countdown starts)
            # or the countdown timer — never both
            vote_ref: nil,
            results_ref: nil,
            # listening-delay timer (:revealing -> :voting)
            vote_delay_ref: nil,
            finished_ref: nil,
            winners: nil

  # =========================================================================
  # Boot
  # =========================================================================

  def start_link(opts) do
    code = Keyword.fetch!(opts, :code)
    GenServer.start_link(__MODULE__, opts, name: via(code))
  end

  @doc "The `:via` tuple used to register/address a game by its code."
  def via(code), do: {:via, Registry, {WhoseJam.Game.Registry, code}}

  @impl true
  def init(opts) do
    state = %__MODULE__{
      code: Keyword.fetch!(opts, :code),
      theme: Keyword.fetch!(opts, :theme),
      overrides: Keyword.get(opts, :overrides, %{}),
      last_activity_ms: now_ms()
    }

    schedule(:ttl_check, @abandoned_ttl_ms)
    {:ok, state}
  end

  # =========================================================================
  # Reads (no broadcast)
  # =========================================================================

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, public_view(state), state}
  end

  def handle_call(:host_state, _from, state) do
    {:reply, host_view(state), state}
  end

  def handle_call({:player_view, player_id}, _from, state) do
    {:reply, player_view(state, player_id), state}
  end

  # =========================================================================
  # Lobby events
  # =========================================================================

  def handle_call({:join, name}, _from, state) do
    role = join_role(state)

    id = generate_id()
    player = %{id: id, name: to_string(name), role: role, connected?: true}

    state =
      %{
        state
        | participants: Map.put(state.participants, id, player),
          order: state.order ++ [id],
          scores: Map.put_new(state.scores, id, 0)
      }
      |> touch()

    result =
      %{player_id: id, role: role}
      |> maybe_flag_audience_cap(state, role)

    {:reply, {:ok, result}, broadcast(state)}
  end

  def handle_call({:rejoin, player_id}, _from, state) do
    case Map.fetch(state.participants, player_id) do
      {:ok, player} ->
        state = set_connected(state, player_id, true) |> touch()
        {:reply, {:ok, %{player_id: player.id, role: player.role}}, broadcast(state)}

      :error ->
        {:reply, {:error, :unknown_player}, state}
    end
  end

  def handle_call({:set_config, overrides}, _from, %{phase: :lobby} = state)
      when is_map(overrides) do
    merged = Map.merge(state.overrides, overrides)
    {:reply, :ok, broadcast(touch(%{state | overrides: merged}))}
  end

  def handle_call({:set_config, _overrides}, _from, state) do
    {:reply, {:error, :not_lobby}, state}
  end

  def handle_call({:set_spotify, spotify}, _from, state) when is_map(spotify) do
    {:reply, :ok, touch(%{state | spotify: spotify})}
  end

  def handle_call(:start_game, _from, state) do
    cond do
      state.phase != :lobby ->
        {:reply, {:error, :already_started}, state}

      role_count(state, :player) < current_config(state).min_players ->
        {:reply, {:error, :not_enough_players}, state}

      is_nil(state.spotify) ->
        {:reply, {:error, :not_authenticated}, state}

      not premium?(state.spotify) ->
        {:reply, {:error, :not_premium}, state}

      true ->
        state = start_game(state)
        {:reply, :ok, broadcast(state)}
    end
  end

  # =========================================================================
  # Answering events
  # =========================================================================

  def handle_call(
        {:submit_song, player_id, question_id, song},
        _from,
        %{phase: :answering} = state
      ) do
    cond do
      not assigned?(state, player_id, question_id) ->
        {:reply, {:error, :not_assigned}, state}

      true ->
        submissions = Map.put(state.submissions, {player_id, question_id}, normalize_song(song))
        state = %{state | submissions: submissions} |> touch() |> maybe_end_answering()
        {:reply, :ok, broadcast(state)}
    end
  end

  def handle_call({:submit_song, _p, _q, _s}, _from, state) do
    {:reply, {:error, :not_answering}, state}
  end

  # =========================================================================
  # Voting / playing events
  # =========================================================================

  def handle_call({:cast_vote, voter_id, choice}, _from, %{round_state: :voting} = state) do
    with {:ok, voter} <- fetch_participant(state, voter_id),
         :ok <- validate_not_submitter(state, voter_id),
         :ok <- validate_choice(state, choice),
         :ok <- validate_can_vote(state, voter_id) do
      votes = Map.put(state.round.votes, voter_id, %{choice: choice, role: voter.role})
      state = %{state | round: %{state.round | votes: votes}} |> touch() |> update_countdown()
      {:reply, :ok, broadcast(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cast_vote, _v, _c}, _from, state) do
    {:reply, {:error, :not_voting}, state}
  end

  # The song is over: open voting if it wasn't already, and make sure the
  # countdown is running so the round can't stall.
  def handle_call(:song_ended, _from, %{phase: :playing, round_state: :revealing} = state) do
    {:reply, :ok, broadcast(state |> begin_voting() |> start_countdown())}
  end

  def handle_call(:song_ended, _from, %{phase: :playing, round_state: :voting} = state) do
    {:reply, :ok, broadcast(start_countdown(state))}
  end

  def handle_call(:song_ended, _from, state) do
    {:reply, {:error, :not_playing}, state}
  end

  def handle_call(:skip_song, _from, %{phase: :playing} = state) do
    state = state |> cancel_round_timers() |> advance_round()
    {:reply, :ok, broadcast(state)}
  end

  def handle_call(:skip_song, _from, state) do
    {:reply, {:error, :not_playing}, state}
  end

  # =========================================================================
  # End / reset
  # =========================================================================

  def handle_call(:play_again, _from, %{phase: :finished} = state) do
    {:reply, :ok, broadcast(reset_to_lobby(state))}
  end

  def handle_call(:play_again, _from, state) do
    {:reply, {:error, :not_finished}, state}
  end

  def handle_call({:presence_diff, connected_ids}, _from, state) do
    connected = MapSet.new(connected_ids)

    participants =
      Map.new(state.participants, fn {id, p} ->
        {id, %{p | connected?: MapSet.member?(connected, id)}}
      end)

    state = %{state | participants: participants}

    # A disconnect may complete the current phase early: it can make the
    # remaining eligible voters "all voted", or remove the last player still
    # blocking answering.
    state =
      cond do
        state.round_state == :voting -> update_countdown(state)
        state.phase == :answering -> maybe_end_answering(state)
        true -> state
      end

    {:reply, :ok, broadcast(state)}
  end

  # Unknown/invalid message: never crash.
  def handle_call(_msg, _from, state) do
    {:reply, {:error, :invalid}, state}
  end

  # =========================================================================
  # Timers
  # =========================================================================

  @impl true
  def handle_info({:answer_timeout, si}, %{phase: :answering, subround_index: si} = state) do
    {:noreply, broadcast(end_answering(state))}
  end

  def handle_info({:vote_delay_timeout, si, ri}, state) do
    if state.phase == :playing and state.round_state == :revealing and
         state.subround_index == si and state.round_index == ri do
      {:noreply, broadcast(begin_voting(state))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:voting_safety, si, ri}, state) do
    if state.phase == :playing and state.round_state == :voting and
         state.subround_index == si and state.round_index == ri do
      {:noreply, broadcast(start_countdown(state))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:vote_timeout, si, ri}, state) do
    if state.phase == :playing and state.round_state == :voting and
         state.subround_index == si and state.round_index == ri do
      {:noreply, broadcast(enter_results(state))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:results_done, si, ri}, state) do
    if state.phase == :playing and state.round_state == :results and
         state.subround_index == si and state.round_index == ri do
      {:noreply, broadcast(advance_round(state))}
    else
      {:noreply, state}
    end
  end

  def handle_info(:finished_shutdown, %{phase: :finished} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:ttl_check, state) do
    idle_ms = now_ms() - state.last_activity_ms

    if state.phase == :lobby and idle_ms >= @abandoned_ttl_ms do
      {:stop, :normal, state}
    else
      schedule(:ttl_check, @abandoned_ttl_ms)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # =========================================================================
  # Start game: build the plan
  # =========================================================================

  defp start_game(state) do
    player_ids = player_ids(state)
    config = Config.build(state.overrides, length(player_ids))

    style_pools =
      state.theme.style_sequence
      |> Enum.uniq()
      |> Map.new(fn style -> {style, Content.game_questions(state.theme.id, style)} end)

    ordered_styles = Enum.uniq(state.theme.style_sequence)
    subrounds = build_subrounds(ordered_styles, config, player_ids, style_pools)

    state = %{
      state
      | config: config,
        style_pools: style_pools,
        subrounds: subrounds,
        subround_index: 0,
        scores: reset_scores(state)
    }

    begin_answering(state, 0)
  end

  # One sub-round per style when enabled; a single all-styles sub-round when
  # not. `ordered_styles` follows the theme's style_sequence.
  defp build_subrounds(ordered_styles, config, player_ids, style_pools) do
    groups =
      if config.subrounds_enabled? do
        Enum.map(ordered_styles, &[&1])
      else
        [ordered_styles]
      end

    Enum.map(groups, fn group ->
      build_subround(group, config, player_ids, style_pools)
    end)
  end

  defp build_subround(styles, config, player_ids, style_pools) do
    {assignments, questions_by_id} =
      Enum.reduce(styles, {%{}, %{}}, fn style, {assign_acc, q_acc} ->
        pool = Map.get(style_pools, style, [])
        assignment = Binning.assign(player_ids, pool, config.questions_per_player)

        by_id = Map.new(pool, fn q -> {q.id, q} end)

        used_questions =
          assignment
          |> Map.keys()
          |> Map.new(fn qid -> {qid, Map.fetch!(by_id, qid)} end)

        {Map.merge(assign_acc, assignment), Map.merge(q_acc, used_questions)}
      end)

    %{styles: styles, assignments: assignments, questions_by_id: questions_by_id}
  end

  # =========================================================================
  # Answering
  # =========================================================================

  defp begin_answering(state, index) do
    subround = Enum.at(state.subrounds, index)
    # Each style in a sub-round asks `questions_per_player` questions, so the
    # answer window scales with how many styles the sub-round covers (1 for a
    # normal sub-round; S for the collapsed all-styles case).
    style_count = max(length(subround.styles), 1)
    ms = state.config.answer_timer_s * style_count * 1000
    ref = schedule({:answer_timeout, index}, ms)

    %{
      state
      | phase: :answering,
        round_state: nil,
        subround_index: index,
        submissions: %{},
        answer_deadline_ms: now_ms() + ms,
        answer_ref: ref,
        rounds: [],
        round_index: 0,
        round: nil,
        vote_deadline_ms: nil
    }
    |> maybe_end_answering_if_empty(subround)
  end

  # A sub-round with no assigned questions has nothing to answer; roll straight
  # into (an empty) playing phase, which advances immediately.
  defp maybe_end_answering_if_empty(state, %{assignments: assignments}) do
    if map_size(assignments) == 0, do: end_answering(state), else: state
  end

  defp maybe_end_answering(state) do
    if all_submitted?(state), do: end_answering(state), else: state
  end

  # Only connected players can still block early completion. A disconnected
  # player's already-submitted songs stay in the game; their *pending*
  # questions no longer hold up the phase.
  defp all_submitted?(state) do
    assignments = current_subround(state).assignments

    Enum.all?(assignments, fn {qid, pids} ->
      Enum.all?(pids, fn pid ->
        not connected?(state, pid) or Map.has_key?(state.submissions, {pid, qid})
      end)
    end)
  end

  defp connected?(state, pid) do
    case Map.fetch(state.participants, pid) do
      {:ok, p} -> p.connected?
      :error -> false
    end
  end

  defp end_answering(state) do
    state = cancel_timer(state, :answer_ref)
    rounds = build_rounds(state)
    begin_playing(%{state | rounds: rounds, round_index: 0})
  end

  # Every submission becomes exactly one round; unanswered questions are dropped.
  defp build_rounds(state) do
    subround = current_subround(state)

    state.submissions
    |> Enum.map(fn {{player_id, qid}, song} ->
      question = Map.fetch!(subround.questions_by_id, qid)
      build_round(state, player_id, qid, question, song)
    end)
    |> Enum.shuffle()
  end

  defp build_round(state, submitter_id, qid, %{style: :guess_who} = question, song) do
    round_map(submitter_id, qid, question, song,
      choices: guess_who_choices(state),
      correct_choice: submitter_id
    )
  end

  defp build_round(state, submitter_id, qid, %{style: :guess_question} = question, song) do
    round_map(submitter_id, qid, question, song,
      choices: guess_question_choices(state, qid, question),
      correct_choice: qid
    )
  end

  # The 10-key round map shared by both styles; `choices` and `correct_choice`
  # are the only style-specific fields. `style` mirrors the question's style.
  defp round_map(submitter_id, qid, %{style: style} = question, song, opts) do
    %{
      style: style,
      submitter_id: submitter_id,
      qid: qid,
      question: question,
      song: song,
      choices: Keyword.fetch!(opts, :choices),
      correct_choice: Keyword.fetch!(opts, :correct_choice),
      votes: %{},
      revealed: false,
      deltas: nil
    }
  end

  defp guess_who_choices(state) do
    state
    |> players_ordered()
    |> Enum.map(fn p -> %{id: p.id, name: p.name} end)
  end

  defp guess_question_choices(state, correct_qid, question) do
    style = question.style

    decoys =
      state.style_pools
      |> Map.get(style, [])
      |> Enum.reject(fn q -> q.id == correct_qid end)
      |> Enum.shuffle()
      |> Enum.take(@guess_question_decoys)

    ([question] ++ decoys)
    |> Enum.shuffle()
    |> Enum.map(fn q -> %{id: q.id, prompt: q.prompt} end)
  end

  # =========================================================================
  # Playing / rounds
  # =========================================================================

  defp begin_playing(%{rounds: []} = state), do: advance_subround(state)

  defp begin_playing(state), do: enter_round(state, 0)

  defp enter_round(state, index) do
    round = Enum.at(state.rounds, index)
    delay_ms = state.config.vote_delay_s * 1000

    state = %{
      state
      | phase: :playing,
        round_state: :revealing,
        round_index: index,
        round: round,
        votes_open_ms: now_ms() + delay_ms,
        vote_deadline_ms: nil,
        vote_ref: nil,
        results_ref: nil
    }

    if delay_ms == 0 do
      begin_voting(state)
    else
      ref = schedule({:vote_delay_timeout, state.subround_index, index}, delay_ms)
      %{state | vote_delay_ref: ref}
    end
  end

  # Open voting while the song keeps playing. No countdown yet — see
  # `update_countdown/1` — but a safety timer (held in `vote_ref` until the
  # countdown replaces it) guarantees one eventually starts.
  defp begin_voting(state) do
    state = cancel_timer(state, :vote_delay_ref)

    ref =
      schedule({:voting_safety, state.subround_index, state.round_index}, voting_safety_ms(state))

    %{
      state
      | round_state: :voting,
        votes_open_ms: now_ms(),
        vote_deadline_ms: nil,
        vote_ref: ref
    }
    |> update_countdown()
  end

  # Majority in → start the countdown; everyone in → cut it to the short final
  # countdown (never lengthening it).
  defp update_countdown(state) do
    cond do
      all_eligible_voted?(state) -> countdown_at_most(state, all_voted_countdown_ms())
      majority_voted?(state) -> start_countdown(state)
      true -> state
    end
  end

  # Start the full countdown unless one is already running.
  defp start_countdown(%{vote_deadline_ms: nil} = state),
    do: countdown_at_most(state, state.config.vote_timer_s * 1000)

  defp start_countdown(state), do: state

  # Set the countdown to end within `ms`, keeping an earlier deadline if any.
  # Replacing `vote_ref` also cancels the safety timer when the countdown first
  # starts.
  defp countdown_at_most(state, ms) do
    deadline = now_ms() + ms

    if state.vote_deadline_ms && state.vote_deadline_ms <= deadline do
      state
    else
      state = cancel_timer(state, :vote_ref)
      ref = schedule({:vote_timeout, state.subround_index, state.round_index}, ms)
      %{state | vote_deadline_ms: deadline, vote_ref: ref}
    end
  end

  defp all_eligible_voted?(state) do
    {eligible, voted} = eligible_vote_counts(state)
    eligible > 0 and voted == eligible
  end

  defp majority_voted?(state) do
    {eligible, voted} = eligible_vote_counts(state)
    eligible > 0 and voted * 2 > eligible
  end

  defp eligible_vote_counts(state) do
    eligible = eligible_voter_ids(state)
    {length(eligible), Enum.count(eligible, &Map.has_key?(state.round.votes, &1))}
  end

  defp eligible_voter_ids(state) do
    submitter = state.round.submitter_id

    state.participants
    |> Map.values()
    |> Enum.filter(fn p -> p.connected? and p.id != submitter end)
    |> Enum.map(& &1.id)
  end

  defp enter_results(state) do
    state = cancel_timer(state, :vote_ref)
    round = state.round

    votes =
      Enum.map(round.votes, fn {voter_id, %{choice: choice, role: role}} ->
        %{voter_id: voter_id, voter_role: role, choice: choice}
      end)

    deltas =
      Scoring.score_round(
        %{
          style: round.style,
          submitter_id: round.submitter_id,
          correct_choice: round.correct_choice
        },
        votes
      )

    scores =
      Enum.reduce(deltas, state.scores, fn {id, delta}, acc ->
        Map.update(acc, id, delta, &(&1 + delta))
      end)

    round = %{round | revealed: true, deltas: deltas}
    ms = results_pause_ms(state)
    ref = schedule({:results_done, state.subround_index, state.round_index}, ms)

    %{state | round_state: :results, round: round, scores: scores, results_ref: ref}
  end

  defp advance_round(state) do
    state = cancel_round_timers(state)
    next = state.round_index + 1

    if next < length(state.rounds) do
      enter_round(state, next)
    else
      advance_subround(state)
    end
  end

  defp advance_subround(state) do
    next = state.subround_index + 1

    if next < length(state.subrounds) do
      begin_answering(state, next)
    else
      finish(state)
    end
  end

  defp finish(state) do
    ref = schedule(:finished_shutdown, @finished_shutdown_ms)

    %{
      state
      | phase: :finished,
        round_state: nil,
        round: nil,
        rounds: [],
        winners: compute_winners(state),
        finished_ref: ref
    }
  end

  defp reset_to_lobby(state) do
    state = cancel_all_timers(state)

    %{
      state
      | phase: :lobby,
        round_state: nil,
        config: nil,
        style_pools: %{},
        subrounds: [],
        subround_index: 0,
        submissions: %{},
        answer_deadline_ms: nil,
        rounds: [],
        round_index: 0,
        round: nil,
        vote_deadline_ms: nil,
        winners: nil,
        scores: reset_scores(state),
        last_activity_ms: now_ms()
    }
  end

  # =========================================================================
  # Winners
  # =========================================================================

  defp compute_winners(state) do
    %{
      players: top_scorers(state, :player),
      audience: top_scorers(state, :audience)
    }
  end

  defp top_scorers(state, role) do
    ids =
      state.participants
      |> Map.values()
      |> Enum.filter(&(&1.role == role))
      |> Enum.map(& &1.id)

    case ids do
      [] ->
        []

      _ ->
        max = ids |> Enum.map(&Map.get(state.scores, &1, 0)) |> Enum.max()
        Enum.filter(ids, fn id -> Map.get(state.scores, id, 0) == max end)
    end
  end

  # =========================================================================
  # Public views
  # =========================================================================

  @doc "The shared public state map broadcast to every client."
  def public_view(state) do
    %{
      code: state.code,
      phase: state.phase,
      round_state: state.round_state,
      theme: theme_view(state.theme),
      config: config_view(state),
      players: players_view(state),
      audience: audience_view(state),
      subround_index: state.subround_index,
      subround_total: length(state.subrounds),
      subround_styles: current_subround_styles(state),
      answering: answering_view(state),
      round: round_view(state),
      scores: state.scores,
      winners: state.winners
    }
  end

  # Host-scoped view: the shared view plus the Spotify auth held in state.
  defp host_view(state) do
    Map.put(public_view(state), :spotify, state.spotify)
  end

  # Player-scoped view: the shared view plus THIS player's own assignments and
  # submissions (which the shared view deliberately hides from everyone else).
  defp player_view(state, player_id) do
    Map.put(public_view(state), :me, me_view(state, player_id))
  end

  defp me_view(state, player_id) do
    case Map.fetch(state.participants, player_id) do
      :error ->
        nil

      {:ok, player} ->
        %{
          id: player.id,
          role: player.role,
          assigned: assigned_view(state, player_id),
          # Per-caller truth (safe here, never in the shared broadcast): is this
          # player the submitter of the round currently in play?
          own_round?: own_round?(state, player_id),
          # How many of this player's assigned questions in the current sub-round
          # went unsubmitted once answering ended. Lets a reconnecting player
          # still learn their unfinished questions were dropped.
          missed_count: missed_count(state, player_id)
        }
    end
  end

  defp own_round?(state, player_id) do
    case state.round do
      %{submitter_id: submitter_id} -> submitter_id == player_id
      _ -> false
    end
  end

  # Only meaningful once answering has ended (the playing phase): the assigned
  # questions this player never submitted. During :answering the player is still
  # submitting, so it is 0.
  defp missed_count(%{phase: :playing} = state, player_id) do
    subround = current_subround(state)

    Enum.count(subround.assignments, fn {qid, pids} ->
      player_id in pids and not Map.has_key?(state.submissions, {player_id, qid})
    end)
  end

  defp missed_count(_state, _player_id), do: 0

  defp assigned_view(%{phase: :answering} = state, player_id) do
    subround = current_subround(state)

    subround.assignments
    |> Enum.filter(fn {_qid, pids} -> player_id in pids end)
    |> Enum.map(fn {qid, _pids} ->
      question = Map.fetch!(subround.questions_by_id, qid)
      song = Map.get(state.submissions, {player_id, qid})

      %{
        question_id: qid,
        prompt: question.prompt,
        style: question.style,
        submitted?: not is_nil(song),
        song: song
      }
    end)
  end

  defp assigned_view(_state, _player_id), do: []

  defp theme_view(nil), do: nil

  defp theme_view(theme) do
    %{
      id: theme.id,
      name: theme.name,
      description: theme.description,
      style_sequence: theme.style_sequence
    }
  end

  defp config_view(state) do
    config = current_config(state)

    %{
      answer_timer_s: config.answer_timer_s,
      vote_timer_s: config.vote_timer_s,
      vote_delay_s: config.vote_delay_s,
      questions_per_player: config.questions_per_player,
      subrounds_enabled?: config.subrounds_enabled?,
      allow_vote_change?: config.allow_vote_change?,
      min_players: config.min_players
    }
  end

  defp players_view(state) do
    state
    |> players_ordered()
    |> Enum.map(&participant_view/1)
  end

  defp audience_view(state) do
    state
    |> ordered_participants()
    |> Enum.filter(&(&1.role == :audience))
    |> Enum.map(&participant_view/1)
  end

  defp participant_view(p) do
    %{id: p.id, name: p.name, role: p.role, connected?: p.connected?}
  end

  defp answering_view(%{phase: :answering} = state) do
    %{deadline_ms: state.answer_deadline_ms, progress: answering_progress(state)}
  end

  defp answering_view(_state), do: nil

  defp answering_progress(state) do
    assignments = current_subround(state).assignments

    state
    |> player_ids()
    |> Map.new(fn pid ->
      total = Enum.count(assignments, fn {_qid, pids} -> pid in pids end)

      submitted =
        Enum.count(assignments, fn {qid, pids} ->
          pid in pids and Map.has_key?(state.submissions, {pid, qid})
        end)

      {pid, %{submitted: submitted, total: total}}
    end)
  end

  defp round_view(%{phase: :playing, round: round} = state) when not is_nil(round) do
    base = %{
      index: state.round_index,
      total: length(state.rounds),
      style: round.style,
      song: round.song,
      choices: round.choices,
      votes_received: map_size(round.votes),
      voters: Map.keys(round.votes),
      votes_open_ms: state.votes_open_ms,
      deadline_ms: state.vote_deadline_ms,
      revealed: round.revealed
    }

    if round.revealed do
      # Post-reveal only: expose the correct answer. `correct_choice` is the
      # submitter id (guess_who) or the question id (guess_question); the choices
      # list always carries the correct one, so `correct_prompt` is derivable for
      # guess_question rounds. NEVER populated before the reveal.
      Map.merge(base, %{
        submitter_id: round.submitter_id,
        deltas: round.deltas,
        correct_choice: round.correct_choice,
        correct_prompt: correct_prompt(round)
      })
    else
      Map.merge(base, %{
        submitter_id: nil,
        deltas: nil,
        correct_choice: nil,
        correct_prompt: nil
      })
    end
  end

  defp round_view(_state), do: nil

  # The prompt of the correct question, for guess_question reveals. The correct
  # question is always among the round's choices (see `guess_question_choices/3`).
  defp correct_prompt(%{style: :guess_question, choices: choices, correct_choice: cid}) do
    case Enum.find(choices, fn c -> c.id == cid end) do
      %{prompt: prompt} -> prompt
      _ -> nil
    end
  end

  defp correct_prompt(_round), do: nil

  # =========================================================================
  # Helpers
  # =========================================================================

  defp join_role(state) do
    cond do
      state.phase != :lobby -> :audience
      role_count(state, :player) >= @max_players -> :audience
      true -> :player
    end
  end

  defp maybe_flag_audience_cap(result, state, :audience) do
    if role_count(state, :audience) > @audience_soft_cap do
      Map.put(result, :audience_soft_cap_exceeded, true)
    else
      result
    end
  end

  defp maybe_flag_audience_cap(result, _state, _role), do: result

  defp assigned?(state, player_id, question_id) do
    case Map.fetch(current_subround(state).assignments, question_id) do
      {:ok, pids} -> player_id in pids
      :error -> false
    end
  end

  defp fetch_participant(state, id) do
    case Map.fetch(state.participants, id) do
      {:ok, p} -> {:ok, p}
      :error -> {:error, :unknown_voter}
    end
  end

  defp validate_not_submitter(state, voter_id) do
    if state.round.submitter_id == voter_id, do: {:error, :own_round}, else: :ok
  end

  defp validate_choice(state, choice) do
    valid = Enum.map(state.round.choices, & &1.id)
    if choice in valid, do: :ok, else: {:error, :invalid_choice}
  end

  defp validate_can_vote(state, voter_id) do
    cond do
      not Map.has_key?(state.round.votes, voter_id) -> :ok
      current_config(state).allow_vote_change? -> :ok
      true -> {:error, :already_voted}
    end
  end

  defp current_subround(state),
    do: Enum.at(state.subrounds, state.subround_index) || empty_subround()

  defp empty_subround, do: %{styles: [], assignments: %{}, questions_by_id: %{}}

  defp current_subround_styles(state) do
    case Enum.at(state.subrounds, state.subround_index) do
      nil -> []
      subround -> subround.styles
    end
  end

  defp current_config(state) do
    state.config || Config.build(state.overrides, max(role_count(state, :player), 1))
  end

  defp ordered_participants(state) do
    Enum.map(state.order, fn id -> Map.fetch!(state.participants, id) end)
  end

  defp players_ordered(state) do
    state |> ordered_participants() |> Enum.filter(&(&1.role == :player))
  end

  defp player_ids(state) do
    state |> players_ordered() |> Enum.map(& &1.id)
  end

  defp role_count(state, role),
    do: Enum.count(state.participants, fn {_id, p} -> p.role == role end)

  defp set_connected(state, id, connected?) do
    case Map.fetch(state.participants, id) do
      {:ok, p} ->
        %{state | participants: Map.put(state.participants, id, %{p | connected?: connected?})}

      :error ->
        state
    end
  end

  defp reset_scores(state), do: Map.new(state.participants, fn {id, _p} -> {id, 0} end)

  defp premium?(spotify) do
    fetch_field(spotify, :premium?) == true
  end

  # Internal pacing durations. Each has an estimator-consistent default; a
  # test-only application-env seam (e.g. `config :whose_jam, results_pause_ms: N`
  # or `Application.put_env/3` in a test) can shorten it. None of these are
  # host-facing settings or overridable via the public create/set_config API.
  defp results_pause_ms(state) do
    env_ms(
      :results_pause_ms,
      (state.config.reveal_padding_s + state.config.results_padding_s) * 1000
    )
  end

  defp voting_safety_ms(state) do
    env_ms(:voting_safety_ms, (state.config.song_playback_s + @voting_safety_extra_s) * 1000)
  end

  defp all_voted_countdown_ms, do: env_ms(:all_voted_countdown_ms, @all_voted_countdown_s * 1000)

  defp env_ms(key, default) do
    case Application.get_env(:whose_jam, key) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> default
    end
  end

  # Fetch a value from a map that may use atom or string keys.
  defp fetch_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_field(_map, _key), do: nil

  defp normalize_song(song) do
    %{
      uri: fetch_field(song, :uri),
      name: fetch_field(song, :name),
      artist: fetch_field(song, :artist),
      album_art_url: song |> fetch_field(:album_art_url) |> safe_album_art_url()
    }
  end

  # The album-art URL comes from the client and ends up in every screen's
  # markup, so only Spotify image-CDN URLs survive; anything else becomes nil.
  defp safe_album_art_url(url) when is_binary(url) do
    if Regex.match?(~r{\Ahttps://i\.scdn\.co/image/[A-Za-z0-9]+\z}, url), do: url, else: nil
  end

  defp safe_album_art_url(_url), do: nil

  # --- timers ---------------------------------------------------------------

  defp schedule(msg, ms), do: Process.send_after(self(), msg, ms)

  defp cancel_timer(state, field) do
    cancel(Map.get(state, field))
    Map.put(state, field, nil)
  end

  defp cancel_round_timers(state) do
    cancel(state.vote_delay_ref)
    cancel(state.vote_ref)
    cancel(state.results_ref)
    %{state | vote_delay_ref: nil, vote_ref: nil, results_ref: nil}
  end

  defp cancel_all_timers(state) do
    cancel(state.answer_ref)
    cancel(state.finished_ref)

    state
    |> cancel_round_timers()
    |> Map.put(:answer_ref, nil)
    |> Map.put(:finished_ref, nil)
  end

  defp cancel(nil), do: :ok
  defp cancel(ref), do: Process.cancel_timer(ref)

  # --- misc -----------------------------------------------------------------

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      WhoseJam.PubSub,
      topic(state.code),
      {:game_state, public_view(state)}
    )

    state
  end

  defp topic(code), do: "game:" <> code

  defp touch(state), do: %{state | last_activity_ms: now_ms()}

  defp now_ms, do: System.system_time(:millisecond)

  defp generate_id, do: :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
end
