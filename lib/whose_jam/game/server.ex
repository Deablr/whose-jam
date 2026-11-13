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
  first of: a majority of eligible voters (everyone connected) have voted, the
  song ends, or a safety timeout. Once every eligible voter has voted the
  countdown drops to 3s (`@all_voted_countdown_s`), or to 5s when votes can be
  changed (`@final_changes_s`: that is the room's last chance to change one, and
  the phones say so before it starts) — never lengthening it.
  When the countdown hits zero the round moves to `:results`.

  The submitter is one of those voters. They don't guess whose song it is:
  their choice is a *forecast* of the wrong answer the room will fall for,
  kept apart from the votes (it is never counted as one) and worth a point if
  it comes true (`WhoseJam.Game.Scoring.forecast_right?/2`). Because everyone
  in the room has something to lock in, who has done so says nothing about
  whose song is playing.

  Sub-rounds come from the theme's `style_sequence`. When
  `config.subrounds_enabled?` is false the sequence collapses into a *single*
  answering phase spanning every style, then a single playing phase over all
  resulting songs.

  ## Host screens and the end of a game

  Each open host screen attaches itself (`WhoseJam.Game.attach_host/2`) and
  the server monitors it. When the last one closes and none comes back within
  a short grace (30s; a refresh or a dropped connection comes back sooner),
  the game ends. While host screens are away signing in to a music service
  (each from `WhoseJam.Game.host_signing_in/1` until its OAuth callback calls
  `WhoseJam.Game.host_back_from_sign_in/2`, for 15 minutes at most) the game
  waits for them that long instead. Until a host screen
  has attached, nothing is watched (the idle timeout covers a game nobody
  opened).

  However the game ends — the host ends it (`WhoseJam.Game.end_game/1`), its
  last host screen goes, or it sits idle — the server broadcasts
  `{:game_ended, reason}` on the room topic (`:host_ended`, `:host_left` or
  `:idle`) and stops, discarding its state.

  ## Contracts

  Callers only ever touch this module through `WhoseJam.Game`. Events go in as
  `GenServer` calls; the resulting public state comes back out via
  `public_view/1` (and is broadcast on `"game:" <> code`). The public view is a
  plain map safe for every client — it never leaks who submitted the current
  song, anyone else's pending submissions, or vote choices before the reveal.
  The host's music-service auth (including any access token) is exposed only
  through the host-scoped `:host_state` query.
  """

  use GenServer, restart: :temporary

  alias WhoseJam.Content
  alias WhoseJam.Game.{Awards, Binning, Config, Scoring}
  alias WhoseJam.Music

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
  # lengthening a shorter remaining countdown): long enough for the room to
  # look up, short enough that eight rounds of it don't drag.
  @all_voted_countdown_s 3
  @final_changes_s 5
  # How long the song-picking screen stays up once everyone has picked.
  @all_in_pause_ms 1_500
  # How long a game outlives its last host screen: long enough for a refresh
  # or a dropped connection to come back. A host screen that left to sign in to
  # a music service gets as long as that sign-in may take (the OAuth state's
  # lifetime in `WhoseJamWeb.MusicAuthController`).
  @host_grace_ms 30 * 1000
  @sign_in_grace_ms 15 * 60 * 1000
  # More sign-ins at once than any room has host screens: a cap on what anyone
  # with the room code can make the game keep track of.
  @max_sign_ins 4

  @guess_question_decoys 3

  # --- server state ---------------------------------------------------------

  defstruct code: nil,
            theme: nil,
            overrides: %{},
            # frozen at start_game; nil while in :lobby
            config: nil,
            # %{provider: id, auth: map} once the host connects a music service
            music: nil,
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
            # when the reveal on screen gives way to the next song (or the
            # final scores); nil outside :results
            results_until_ms: nil,
            # listening-delay timer (:revealing -> :voting)
            vote_delay_ref: nil,
            finished_ref: nil,
            winners: nil,
            # Every round played to a reveal, newest first (`Awards.played_round`)
            history: [],
            # Host screens (see the moduledoc):
            #   screens        monitor ref => pid of each open one
            #   gone           {token, timer} while none is open
            #   left_at_ms     when the last one closed
            #   sign_ins       sign-in id => when its window closes (ms), for
            #                  each host screen away signing in
            host: %{screens: %{}, gone: nil, left_at_ms: nil, sign_ins: %{}}

  # =========================================================================
  # Boot
  # =========================================================================

  def start_link(opts) do
    code = Keyword.fetch!(opts, :code)
    GenServer.start_link(__MODULE__, opts, name: via(code))
  end

  @doc "How many joiners are players; anyone after that joins as audience."
  @spec max_players() :: pos_integer()
  def max_players, do: @max_players

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

    schedule(:ttl_check, abandoned_ttl_ms())
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

  def handle_call({:set_music, provider_id, auth}, _from, state) when is_map(auth) do
    case Music.fetch_provider(provider_id) do
      :error ->
        {:reply, {:error, :unknown_provider}, state}

      {:ok, mod} ->
        if switching_mid_game?(state, mod.id()) do
          {:reply, {:error, :not_lobby}, state}
        else
          # Broadcast: the public view carries which service this is, and the
          # host screen re-derives its player from the change.
          state = touch(%{state | music: %{provider: mod.id(), auth: auth}})
          {:reply, :ok, broadcast(state)}
        end
    end
  end

  def handle_call(:start_game, _from, state) do
    cond do
      state.phase != :lobby ->
        {:reply, {:error, :already_started}, state}

      role_count(state, :player) < current_config(state).min_players ->
        {:reply, {:error, :not_enough_players}, state}

      is_nil(state.music) ->
        {:reply, {:error, :not_authenticated}, state}

      not music_eligible?(state.music) ->
        {:reply, {:error, :not_eligible}, state}

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
    with true <- assigned?(state, player_id, question_id) || {:error, :not_assigned},
         {:ok, song} <- normalize_song(state, song) do
      submissions = Map.put(state.submissions, {player_id, question_id}, song)
      state = %{state | submissions: submissions} |> touch() |> maybe_end_answering()
      {:reply, :ok, broadcast(state)}
    else
      {:error, _reason} = error -> {:reply, error, state}
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
         :ok <- validate_choice(state, choice),
         :ok <- validate_can_vote(state, voter_id) do
      round = record_choice(state.round, voter, choice)
      state = %{state | round: round} |> touch() |> update_countdown()
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

  def handle_call(:end_game, _from, state) do
    {:stop, :normal, :ok, announce_end(state, :host_ended)}
  end

  # =========================================================================
  # Host screens
  # =========================================================================

  # A host screen is back (or opened): the game no longer counts down to its
  # end. A sign-in still under way elsewhere keeps its window: this may be a
  # second host screen, not the one that left to sign in.
  def handle_call({:attach_host, pid}, _from, state) when is_pid(pid) do
    screens =
      if pid in Map.values(state.host.screens),
        do: state.host.screens,
        else: Map.put(state.host.screens, Process.monitor(pid), pid)

    state = cancel_host_gone(state)
    {:reply, :ok, %{state | host: %{state.host | screens: screens}}}
  end

  # Each sign-in let in gets an id, which only its own OAuth callback can end
  # (see `host_back_from_sign_in`). One that never comes back drops out when
  # its window closes. Past @max_sign_ins at once, new ones are refused rather
  # than pushing out one under way.
  def handle_call(:host_signing_in, _from, state) do
    sign_ins = open_sign_ins(state)

    cond do
      not host_may_sign_in?(state) ->
        {:reply, {:error, :no_host_screen}, state}

      map_size(sign_ins) >= @max_sign_ins ->
        {:reply, {:error, :too_many_sign_ins}, state}

      true ->
        id = generate_id()
        sign_ins = Map.put(sign_ins, id, now_ms() + sign_in_grace_ms())
        {:reply, {:ok, id}, %{state | host: %{state.host | sign_ins: sign_ins}}}
    end
  end

  # A sign-in is over, whatever came of it. Its host screen is on its way
  # back, so if none is open the usual grace applies again from now (still
  # deferring to any other sign-in under way). Only an id that was let in
  # and is still under way counts, and only once.
  def handle_call({:host_back_from_sign_in, id}, _from, state) do
    if Map.has_key?(state.host.sign_ins, id) do
      state = %{state | host: %{state.host | sign_ins: Map.delete(state.host.sign_ins, id)}}
      state = if state.host.gone, do: schedule_host_gone(state, host_grace_ms()), else: state
      {:reply, :ok, state}
    else
      {:reply, {:error, :unknown_sign_in}, state}
    end
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
    {:stop, :normal, announce_end(state, :idle)}
  end

  # The last host screen closed: give it the grace to come back.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{host: %{screens: screens}} = state)
      when is_map_key(screens, ref) do
    screens = Map.delete(screens, ref)

    if map_size(screens) == 0 do
      state = %{state | host: %{state.host | screens: screens, left_at_ms: now_ms()}}
      {:noreply, schedule_host_gone(state, host_grace_ms())}
    else
      {:noreply, %{state | host: %{state.host | screens: screens}}}
    end
  end

  # No host screen came back in time, unless one is away signing in: then it
  # has until its sign-in window closes.
  def handle_info({:host_gone, token}, %{host: %{gone: {token, _timer}}} = state) do
    case away_ms_left(state) do
      ms when ms > 0 -> {:noreply, schedule_host_gone(state, ms)}
      _none -> {:stop, :normal, announce_end(state, :host_left)}
    end
  end

  def handle_info(:ttl_check, state) do
    idle_ms = now_ms() - state.last_activity_ms

    if state.phase == :lobby and idle_ms >= abandoned_ttl_ms() do
      {:stop, :normal, announce_end(state, :idle)}
    else
      schedule(:ttl_check, abandoned_ttl_ms())
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

  # Once everyone is in, the phase ends after a short pause rather than at
  # once: the room sees the last player lock in (and that player sees their
  # own pick confirmed) before the first song starts. A change of pick during
  # the pause just starts it again.
  defp maybe_end_answering(state) do
    cond do
      not all_submitted?(state) -> state
      all_in_pause_ms() == 0 -> end_answering(state)
      true -> end_answering_soon(state)
    end
  end

  defp end_answering_soon(state) do
    state = cancel_timer(state, :answer_ref)
    ms = all_in_pause_ms()
    ref = schedule({:answer_timeout, state.subround_index}, ms)
    %{state | answer_ref: ref, answer_deadline_ms: now_ms() + ms}
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
      # The submitter's own choice: which wrong answer the room will fall for.
      forecast: nil,
      revealed: false,
      deltas: nil
    }
  end

  # The submitter's choice is their forecast; anyone else's is a vote.
  defp record_choice(%{submitter_id: id} = round, %{id: id}, choice),
    do: %{round | forecast: choice}

  defp record_choice(round, voter, choice),
    do: %{round | votes: Map.put(round.votes, voter.id, %{choice: choice, role: voter.role})}

  # Everyone who has locked something in: the voters, and the submitter once
  # their forecast is in.
  defp locked_in(%{forecast: nil} = round), do: Map.keys(round.votes)
  defp locked_in(round), do: [round.submitter_id | Map.keys(round.votes)]

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
        results_ref: nil,
        results_until_ms: nil
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
      all_eligible_voted?(state) -> countdown_at_most(state, all_voted_countdown_ms(state))
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
    locked = locked_in(state.round)
    {length(eligible), Enum.count(eligible, &(&1 in locked))}
  end

  # Everyone connected has something to lock in: a vote, or (the submitter)
  # a forecast.
  defp eligible_voter_ids(state) do
    for p <- Map.values(state.participants), p.connected?, do: p.id
  end

  defp enter_results(state) do
    state = cancel_timer(state, :vote_ref)
    round = state.round

    deltas =
      Scoring.score_round(
        scoring_round(round),
        vote_list(round)
      )

    scores =
      Enum.reduce(deltas, state.scores, fn {id, delta}, acc ->
        Map.update(acc, id, delta, &(&1 + delta))
      end)

    round = %{round | revealed: true, deltas: deltas}
    ms = results_pause_ms(state)
    ref = schedule({:results_done, state.subround_index, state.round_index}, ms)

    %{
      state
      | round_state: :results,
        round: round,
        scores: scores,
        results_ref: ref,
        results_until_ms: now_ms() + ms,
        history: [played_round(round) | state.history]
    }
  end

  # The round as `Scoring` takes it.
  defp scoring_round(round) do
    %{
      style: round.style,
      submitter_id: round.submitter_id,
      correct_choice: round.correct_choice,
      forecast: round.forecast
    }
  end

  # What the awards remember of a round: who picked it, how many players they
  # fooled and which players called it.
  defp played_round(round) do
    called =
      for {voter_id, %{choice: choice, role: :player}} <- round.votes,
          choice == round.correct_choice,
          do: voter_id

    %{
      submitter_id: round.submitter_id,
      song_name: round.song.name,
      artist: round.song.artist,
      album_art_url: round.song.album_art_url,
      fooled:
        Enum.count(round.votes, fn {_id, vote} ->
          vote.role == :player and vote.choice != round.correct_choice
        end),
      called: called,
      # The submitter's blame guess came true.
      blamed?: Scoring.forecast_right?(scoring_round(round), vote_list(round))
    }
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
    ref = schedule(:finished_shutdown, env_ms(:finished_shutdown_ms, @finished_shutdown_ms))

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
        history: [],
        participants: seat_audience(state),
        scores: reset_scores(state),
        last_activity_ms: now_ms()
    }
  end

  # A new game has player seats to fill: whoever watched the last one from the
  # audience (they arrived after it started) takes any that are free, in the
  # order they joined.
  defp seat_audience(state) do
    free = @max_players - role_count(state, :player)

    state
    |> ordered_participants()
    |> Enum.filter(&(&1.role == :audience))
    |> Enum.take(max(free, 0))
    |> Enum.reduce(state.participants, fn p, acc -> Map.put(acc, p.id, %{p | role: :player}) end)
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
      music: music_view(state.music),
      config: config_view(state),
      players: players_view(state),
      audience: audience_view(state),
      subround_index: state.subround_index,
      subround_total: length(state.subrounds),
      subround_styles: current_subround_styles(state),
      answering: answering_view(state),
      round: round_view(state),
      scores: state.scores,
      winners: state.winners,
      awards: awards_view(state),
      playlist: playlist_view(state)
    }
  end

  # The night's songs in the order they were played, with who picked each:
  # what a finished game leaves the room with.
  defp playlist_view(%{phase: :finished, history: history}) do
    history
    |> Enum.reverse()
    |> Enum.map(
      &%{
        player_id: &1.submitter_id,
        song_name: &1.song_name,
        artist: &1.artist,
        album_art_url: &1.album_art_url
      }
    )
  end

  defp playlist_view(_state), do: nil

  # Only a finished game has awards to give.
  defp awards_view(%{phase: :finished, history: history}),
    do: history |> Enum.reverse() |> Awards.summarize()

  defp awards_view(_state), do: nil

  # Host-scoped view: the shared view plus the music-service auth held in state.
  defp host_view(state) do
    Map.put(public_view(state), :music_auth, state.music && state.music.auth)
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
          # This player's own vote in the round in play (`nil` until they
          # vote), so their phone can say what they picked even after a
          # reconnect. Everyone else's votes stay hidden until the reveal.
          vote: own_vote(state, player_id),
          # Once the game is finished: how this player's own game went.
          recap: recap(state, player_id),
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

  # How many songs this player called, how many players their own songs
  # fooled, and how many of their blame guesses came true, over the rounds
  # that reached a reveal.
  defp recap(%{phase: :finished, history: history}, player_id) do
    own = Enum.filter(history, &(&1.submitter_id == player_id))

    %{
      called: Enum.count(history, &(player_id in &1.called)),
      fooled: Enum.sum_by(own, & &1.fooled),
      blamed: Enum.count(own, & &1.blamed?)
    }
  end

  defp recap(_state, _player_id), do: nil

  defp own_vote(%{round: %{submitter_id: player_id, forecast: forecast}}, player_id),
    do: forecast

  defp own_vote(%{round: %{votes: votes}}, player_id) do
    case votes do
      %{^player_id => %{choice: choice}} -> choice
      _ -> nil
    end
  end

  defp own_vote(_state, _player_id), do: nil

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
      min_players: config.min_players,
      quick_reveals?: config.quick_reveals?,
      name_non_voters?: config.name_non_voters?,
      show_places?: config.show_places?,
      final_suspense?: config.final_suspense?
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
      prompt: public_prompt(round),
      prompt_take: prompt_take(state, round),
      choices: round.choices,
      # Who has locked something in, and how many the round is waiting for
      # (everyone connected). The submitter is among them (their forecast
      # counts here, though it is no vote), so a screen can name who is in
      # and who isn't without giving the submitter away.
      votes_received: length(locked_in(round)),
      voters: locked_in(round),
      eligible_voters: length(eligible_voter_ids(state)),
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
        votes: vote_list(round),
        forecast: forecast_view(round),
        correct_choice: round.correct_choice,
        correct_prompt: correct_prompt(round),
        # When this reveal moves on, so a screen can say "next song in…".
        next_ms: state.results_until_ms
      })
    else
      Map.merge(base, %{
        submitter_id: nil,
        deltas: nil,
        votes: nil,
        forecast: nil,
        correct_choice: nil,
        correct_prompt: nil,
        next_ms: nil
      })
    end
  end

  defp round_view(_state), do: nil

  # What the submitter forecast, and whether it came true.
  defp forecast_view(%{forecast: nil}), do: nil

  defp forecast_view(round) do
    %{
      choice: round.forecast,
      right?: Scoring.forecast_right?(scoring_round(round), vote_list(round))
    }
  end

  # Who voted for what, as the Vote shape `Scoring.score_round/2` takes.
  defp vote_list(round) do
    Enum.map(round.votes, fn {voter_id, %{choice: choice, role: role}} ->
      %{voter_id: voter_id, voter_role: role, choice: choice}
    end)
  end

  # The prompt the song was picked for, shown from the start of a :guess_who
  # round so the room knows what the question was. A :guess_question round's
  # prompt is what voters guess, so it only appears at the reveal, as
  # `correct_prompt`.
  defp public_prompt(%{style: :guess_who, question: %{prompt: prompt}}), do: prompt
  defp public_prompt(_round), do: nil

  # When several songs were picked for the same prompt, which of them this
  # round is (`%{nth: 2, of: 3, back_to_back?: true}`), so a prompt that comes
  # round again reads as the next answer to it rather than a repeat.
  # `back_to_back?` says the round just before this one had the same prompt.
  # `nil` for a prompt with one song, and wherever the prompt itself is secret.
  defp prompt_take(state, %{style: :guess_who, qid: qid}) do
    same = for {round, index} <- Enum.with_index(state.rounds), round.qid == qid, do: index

    case same do
      [_, _ | _] ->
        %{
          nth: (Enum.find_index(same, &(&1 == state.round_index)) || 0) + 1,
          of: length(same),
          back_to_back?: (state.round_index - 1) in same
        }

      _ ->
        nil
    end
  end

  defp prompt_take(_state, _round), do: nil

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

  defp validate_choice(state, choice) do
    valid = Enum.map(state.round.choices, & &1.id)
    if choice in valid, do: :ok, else: {:error, :invalid_choice}
  end

  defp validate_can_vote(state, voter_id) do
    cond do
      voter_id not in locked_in(state.round) -> :ok
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

  # Switching service mid-game would strand every submitted song; a
  # same-provider update (a token refresh) is always fine.
  defp switching_mid_game?(%{phase: :lobby}, _provider_id), do: false

  defp switching_mid_game?(%{music: %{provider: provider}}, provider_id),
    do: provider != provider_id

  defp switching_mid_game?(_state, _provider_id), do: false

  defp music_eligible?(%{provider: provider, auth: auth}) do
    case Music.fetch_provider(provider) do
      {:ok, mod} -> mod.eligible?(auth)
      :error -> false
    end
  end

  # The part of the music service every client may see: which service it is,
  # whether the host's account can play, and how patiently the player screens
  # should search it. Never the auth itself.
  defp music_view(nil), do: nil

  defp music_view(%{provider: provider} = music) do
    case Music.fetch_provider(provider) do
      {:ok, mod} ->
        %{
          id: mod.id(),
          name: mod.name(),
          video?: mod.video?(),
          eligible?: music_eligible?(music),
          search_debounce_ms: mod.search_debounce_ms()
        }

      :error ->
        nil
    end
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

  defp all_voted_countdown_ms(state) do
    if current_config(state).allow_vote_change?,
      do: env_ms(:all_voted_countdown_ms, @final_changes_s * 1000),
      else: env_ms(:all_voted_countdown_ms, @all_voted_countdown_s * 1000)
  end

  defp all_in_pause_ms, do: env_ms(:all_in_pause_ms, @all_in_pause_ms)

  defp abandoned_ttl_ms, do: env_ms(:abandoned_ttl_ms, @abandoned_ttl_ms)

  defp host_grace_ms, do: env_ms(:host_grace_ms, @host_grace_ms)

  defp sign_in_grace_ms, do: env_ms(:sign_in_grace_ms, @sign_in_grace_ms)

  defp env_ms(key, default) do
    case Application.get_env(:whose_jam, key) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> default
    end
  end

  # The whole song comes from the client; the room's music provider decides what
  # a valid uri / art URL looks like (see `WhoseJam.Music.Track`).
  defp normalize_song(%{music: %{provider: provider}}, song),
    do: Music.normalize_track(provider, song)

  defp normalize_song(_state, _song), do: {:error, :invalid_song}

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

  # The token tells a live countdown from a stale one already in the mailbox.
  defp schedule_host_gone(state, ms) do
    state = cancel_host_gone(state)
    token = make_ref()
    %{state | host: %{state.host | gone: {token, schedule({:host_gone, token}, ms)}}}
  end

  defp cancel_host_gone(%{host: %{gone: {_token, timer}}} = state) do
    cancel(timer)
    %{state | host: %{state.host | gone: nil}}
  end

  defp cancel_host_gone(state), do: state

  # How long the latest-closing sign-in window has left (<= 0 when none is open).
  defp away_ms_left(state) do
    case state.host.sign_ins |> Map.values() |> Enum.max(fn -> nil end) do
      nil -> 0
      until -> until - now_ms()
    end
  end

  # The sign-ins whose window hasn't closed yet.
  defp open_sign_ins(state) do
    now = now_ms()
    Map.filter(state.host.sign_ins, fn {_id, until} -> until > now end)
  end

  # Whether a sign-in notice can be a host screen's: while one is open (the
  # usual case: Connect is a plain link, so the page stays connected until the
  # provider's page loads, after the OAuth controller's notice), or within the
  # grace after the last one closed, for a screen that dropped first (a lost
  # connection just before the click, say). Later, with no host screen around,
  # the notice can't be a host's, and anyone with the room code could
  # otherwise keep a hostless game waiting.
  defp host_may_sign_in?(%{host: %{screens: screens}}) when map_size(screens) > 0, do: true

  defp host_may_sign_in?(%{host: %{left_at_ms: left_at}}) when is_integer(left_at),
    do: now_ms() - left_at <= host_grace_ms()

  defp host_may_sign_in?(_state), do: false

  # --- misc -----------------------------------------------------------------

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      WhoseJam.PubSub,
      topic(state.code),
      {:game_state, public_view(state)}
    )

    state
  end

  # The last word before the process stops: every screen learns the game is
  # over rather than waiting on a server that is gone.
  defp announce_end(state, reason) do
    Phoenix.PubSub.broadcast(WhoseJam.PubSub, topic(state.code), {:game_ended, reason})
    state
  end

  defp topic(code), do: "game:" <> code

  defp touch(state), do: %{state | last_activity_ms: now_ms()}

  defp now_ms, do: System.system_time(:millisecond)

  defp generate_id, do: :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
end
