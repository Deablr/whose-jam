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
             (:intro, before a theme's first sub-round) ──▶
             :answering ──▶ :playing
                              ├─ round :revealing  (listening delay: song plays, votes closed for vote_delay_s)
                              ├─ round :voting     (song keeps playing; clients guess)
                              └─ round :results    (submitter + deltas revealed)
             ...next sub-round or...
        └─ :finished

  ## How each round is played

  Each theme is a round of the game, and opens with `:intro`: a short spell
  (`@intro_ms`) in which every screen tells the room how this round is
  played, before its songs are picked. Its deadline is the public view's
  `intro`; the host can cut it short (`WhoseJam.Game.skip_song/1`).

  ## Voting countdown

  `:voting` opens with no deadline. The `vote_timer_s` countdown starts at the
  first of: a majority of eligible voters (everyone connected) have voted, the
  song ends, or a safety timeout. Once every eligible voter has voted the
  countdown drops to 3s (`@all_voted_countdown_s`), or to 5s when votes can be
  changed (`@final_changes_s`: that is the room's last chance to change one, and
  the phones say so before it starts) — never lengthening it.
  When the countdown hits zero the round moves to `:results`.

  The submitter is one of those voters. They don't guess whose song it is:
  their choice is a *forecast* of the wrong answer the room will fall for
  (or, naming themselves, that nobody will fall for it), kept apart from the
  votes (it is never counted as one) and worth a point if it comes true
  (`WhoseJam.Game.Scoring.forecast_right?/2`). Because everyone
  in the room has something to lock in, who has done so says nothing about
  whose song is playing.

  A game plays one or more themes, in the order the host chose them, and
  each theme is played on its own: its songs are all picked, then all played,
  before the next theme's picking starts. Within a theme, sub-rounds come
  from its `style_sequence`. When `config.subrounds_enabled?` is false a
  theme's sequence collapses into a *single* answering phase spanning every
  style, then a single playing phase over all resulting songs. Once a
  sub-round's picking ends, a random `config.songs_played_pct` of its songs
  are played (`WhoseJam.Game.Config.songs_to_play/2`).

  A player can leave, and the host can remove anyone, until the game is
  finished. The server says so on the room topic first
  (`{:participant_removed, id, reason}`, `reason` `:left` or `:removed`), then
  forgets them: their songs still to come are dropped, and they stop being a
  choice in the rounds still to come.

  Once a vote's countdown is running, anyone who has locked in can give the
  song another second (`WhoseJam.Game.extend_song/2`), as often as they like.

  When the game is finished, a winner can pick one of their own songs that
  were played to play the night out (`WhoseJam.Game.pick_finale/3`).

  ## Head to head

  A `:vs` sub-round asks everyone the same one prompt, then plays the songs
  against each other in a bracket (`WhoseJam.Game.Bracket`) instead of one
  round per song. Each matchup is a round, and its vote is open, and public
  (the view's `vs.ballots`), from the first note: the first song (`"a"`)
  plays a clip (`@vs_clip_s`, from `@vs_start_s` into the song), then the
  second (`"b"`; the TV reporting a song's end moves on early); then the song
  with the most votes plays (`WhoseJam.Game.Bracket.leader/2`), switching
  whenever the lead changes (the TV resumes each where it left off), while
  the countdown runs; at `:results` the pickers are named and the winner
  goes through. When a stage's matchups are done the winners (and
  any bye) make the next stage, until one song is left, whose picker gets
  `WhoseJam.Game.Bracket.champion_bonus/0`.

  ## Host screens and the end of a game

  Each open host screen attaches itself (`WhoseJam.Game.attach_host/2`) and
  the server monitors it. When the last one closes and none comes back within
  a short grace (30s; a refresh or a dropped connection comes back sooner),
  the game ends. While host screens are away signing in to a music service
  (each from `WhoseJam.Game.host_signing_in/2` until its OAuth callback calls
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
  alias WhoseJam.Game.{Awards, Binning, Bracket, Config, Scoring}
  alias WhoseJam.Music

  # --- capacity / timing constants -----------------------------------------

  @audience_soft_cap 20

  # Idle guards. Kept large so they never interfere with a live game or a test;
  # they exist so an abandoned/finished game eventually frees its process.
  @finished_shutdown_ms 5 * 60 * 1000
  # A victory song keeps the final screen up at least this long.
  @finale_shutdown_ms 10 * 60 * 1000
  @abandoned_ttl_ms 60 * 60 * 1000
  # Defensive ceiling on uncounted voting, in case the TV never reports the song
  # ending and nobody votes. Real clients call `song_ended/2` well before this.
  @voting_safety_extra_s 120
  # Once every eligible voter has voted the countdown drops to this (never
  # lengthening a shorter remaining countdown): long enough for the room to
  # look up, short enough that eight rounds of it don't drag.
  @all_voted_countdown_s 3
  @final_changes_s 5
  # How long the song-picking screen stays up once everyone has picked.
  @all_in_pause_ms 1_500
  # How long a round's how-to-play screen stays up before its picking starts.
  @intro_ms 15_000
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
  # How long each song of a head-to-head matchup plays before the next, and
  # how far into each song its clip starts.
  @vs_clip_s 15
  @vs_start_s 15
  # Once both clips are heard and everyone is in, the clock is cut to this
  # (never lengthened), so the room's pick is heard before the reveal.
  @vs_all_in_s 10
  # A tap on "one more second" faster than this is the same tap.
  @extend_tap_ms 150
  # How much one tap gives the song.
  @extend_ms 1_000

  # --- server state ---------------------------------------------------------

  defstruct code: nil,
            # the themes, in the order they are played (at least one)
            themes: [],
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
            # [%{theme_id, styles, assignments, questions_by_id, pools}], `pools`
            # being style => the theme's [runtime_question] of that style
            subrounds: [],
            subround_index: 0,
            # answering scope
            submissions: %{},
            # how quickly everyone picks their songs:
            #   started_ms  when this sub-round's picking started
            #   finished    player id => ms from then to their last pick
            #   times       player id => total ms over the sub-rounds, or
            #               :dnf for a player who once didn't pick them all
            picking: %{started_ms: nil, finished: %{}, times: %{}},
            answer_deadline_ms: nil,
            # how long the answer window that ends at answer_deadline_ms is
            # (for the screens' draining bars)
            answer_window_ms: nil,
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
            winners: nil,
            # once finished: the winner's song that plays the night out
            # (`finale`: %{player_id, song}) and the link to the playlist the
            # host saved (`saved_playlist`)
            # (`until_ms`: when the finished game closes, if left alone)
            ending: %{finale: nil, saved_playlist: nil, until_ms: nil},
            # Every round played to a reveal, newest first (`Awards.played_round`)
            history: [],
            # Host screens (see the moduledoc):
            #   screens        monitor ref => pid of each open one
            #   gone           {token, timer} while none is open
            #   left_at_ms     when the last one closed
            #   sign_ins       sign-in id => when its window closes (ms), for
            #                  each host screen away signing in
            # and what the host has chosen for the room:
            #   phone_hosts    players they let start the game from their
            #                  phones (ids, in the order chosen)
            #   background     the music the TV plays under the lobby and the
            #                  song-picking (a normalized song, or nil)
            #   background_off? the host turned it off, which a token refresh
            #                  keeps
            host: %{
              screens: %{},
              gone: nil,
              left_at_ms: nil,
              sign_ins: %{},
              phone_hosts: [],
              background: nil,
              background_off?: false
            }

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
      themes: Keyword.fetch!(opts, :themes),
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
    case clean_name(name, current_config(state).name_max_length) do
      "" -> {:reply, {:error, :invalid_name}, state}
      name -> join(state, name)
    end
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

  # A player leaving, or the host removing anyone, until the game is over.
  def handle_call({:remove, id, reason}, _from, state) when state.phase != :finished do
    if Map.has_key?(state.participants, id) do
      Phoenix.PubSub.broadcast(
        WhoseJam.PubSub,
        topic(state.code),
        {:participant_removed, id, reason}
      )

      state = state |> forget_participant(id) |> drop_from_play(id) |> seat_waiting() |> touch()
      {:reply, :ok, broadcast(state)}
    else
      {:reply, {:error, :unknown_player}, state}
    end
  end

  def handle_call({:remove, _id, _reason}, _from, state) do
    {:reply, {:error, :finished}, state}
  end

  # More seats seat whoever an earlier cap sent to the audience (see
  # `seat_waiting/1`).
  def handle_call({:set_config, overrides}, _from, %{phase: :lobby} = state)
      when is_map(overrides) do
    state = seat_waiting(%{state | overrides: Map.merge(state.overrides, overrides)})
    {:reply, :ok, broadcast(touch(state))}
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
          previous = state.music && state.music.provider

          state =
            %{state | music: %{provider: mod.id(), auth: auth}}
            |> with_background(mod, previous)
            |> touch()

          {:reply, :ok, broadcast(state)}
        end
    end
  end

  def handle_call(:start_game, _from, state), do: try_start(state)

  # A player the host made a host starts the game from their phone.
  def handle_call({:start_game, player_id}, _from, state) do
    if player_id in state.host.phone_hosts do
      try_start(state)
    else
      {:reply, {:error, :not_host}, state}
    end
  end

  def handle_call({:set_phone_host, player_id, host?}, _from, %{phase: :lobby} = state)
      when is_boolean(host?) do
    case Map.fetch(state.participants, player_id) do
      {:ok, %{role: :player}} ->
        hosts = List.delete(state.host.phone_hosts, player_id)
        hosts = if host?, do: hosts ++ [player_id], else: hosts
        {:reply, :ok, broadcast(touch(put_host(state, phone_hosts: hosts)))}

      _other ->
        {:reply, {:error, :unknown_player}, state}
    end
  end

  def handle_call({:set_phone_host, _id, _host?}, _from, state) do
    {:reply, {:error, :not_lobby}, state}
  end

  # `song` nil turns the background music off.
  def handle_call({:set_background, nil}, _from, %{phase: :lobby} = state) do
    {:reply, :ok, broadcast(touch(put_host(state, background: nil, background_off?: true)))}
  end

  def handle_call({:set_background, song}, _from, %{phase: :lobby} = state) do
    with %{music: %{}} <- state,
         {:ok, track} <- normalize_song(state, song) do
      {:reply, :ok, broadcast(touch(put_host(state, background: track, background_off?: false)))}
    else
      %{music: nil} -> {:reply, {:error, :no_music}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:set_background, _song}, _from, state) do
    {:reply, {:error, :not_lobby}, state}
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

      state =
        %{state | submissions: submissions}
        |> note_finished_picking(player_id)
        |> touch()
        |> maybe_end_answering()

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
      round = record_choice(state.round, voter, choice, now_ms() - state.votes_open_ms)
      state = %{state | round: round} |> touch() |> play_leader() |> update_countdown()
      {:reply, :ok, broadcast(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cast_vote, _v, _c}, _from, state) do
    {:reply, {:error, :not_voting}, state}
  end

  # The song is over: open voting if it wasn't already, and make sure the
  # countdown is running so the round can't stall. A report about a song the
  # round isn't playing (it has moved on, as a head-to-head matchup does when
  # the lead changes) is stale, and changes nothing.
  def handle_call(
        {:song_ended, uri},
        _from,
        %{phase: :playing, round: %{song: %{uri: playing}}} = state
      )
      when is_binary(uri) and uri != playing do
    {:reply, :ok, state}
  end

  def handle_call(
        {:song_ended, _uri},
        _from,
        %{phase: :playing, round_state: :voting, round: %{style: :vs} = round} = state
      ) do
    state = if round.clips_done?, do: vs_song_over(state), else: vs_next(state)
    {:reply, :ok, broadcast(state)}
  end

  def handle_call({:song_ended, _uri}, _from, %{phase: :playing, round_state: :revealing} = state) do
    {:reply, :ok, broadcast(state |> begin_voting() |> start_countdown())}
  end

  def handle_call({:song_ended, _uri}, _from, %{phase: :playing, round_state: :voting} = state) do
    {:reply, :ok, broadcast(start_countdown(state))}
  end

  def handle_call({:song_ended, _uri}, _from, state) do
    {:reply, {:error, :not_playing}, state}
  end

  # Another second of the song, from anyone who has locked in, once the
  # countdown is running.
  def handle_call({:extend_song, player_id}, _from, %{round_state: :voting} = state)
      when is_integer(state.vote_deadline_ms) do
    last = Map.get(state.round.extend_taps, player_id, 0)

    cond do
      player_id not in locked_in(state.round) ->
        {:reply, {:error, :not_locked_in}, state}

      now_ms() - last < @extend_tap_ms ->
        {:reply, {:error, :too_fast}, state}

      true ->
        state = extend_countdown(state, player_id)
        {:reply, :ok, broadcast(touch(state))}
    end
  end

  def handle_call({:extend_song, _player_id}, _from, state) do
    {:reply, {:error, :no_countdown}, state}
  end

  def handle_call({:pick_finale, player_id, uri}, _from, %{phase: :finished} = state) do
    with true <- player_id in state.winners.players || {:error, :not_winner},
         true <- is_nil(state.ending.finale) || {:error, :already_picked},
         %{} = played <- own_played_song(state, player_id, uri) || {:error, :not_played} do
      song = Map.take(played, [:uri, :song_name, :artist, :album_art_url])

      state =
        put_in(state.ending.finale, %{player_id: player_id, song: song})
        |> touch()
        |> keep_finished(finale_shutdown_ms())

      {:reply, :ok, broadcast(state)}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:pick_finale, _player_id, _uri}, _from, state) do
    {:reply, {:error, :not_finished}, state}
  end

  def handle_call(
        {:set_saved_playlist, "https://" <> _ = url},
        _from,
        %{phase: :finished} = state
      )
      when byte_size(url) <= 500 do
    state = touch(put_in(state.ending.saved_playlist, url))
    {:reply, :ok, broadcast(keep_finished(state, finished_shutdown_ms()))}
  end

  def handle_call({:set_saved_playlist, _url}, _from, %{phase: :finished} = state) do
    {:reply, {:error, :bad_link}, state}
  end

  def handle_call({:set_saved_playlist, _url}, _from, state) do
    {:reply, {:error, :not_finished}, state}
  end

  # The host skips a round's how-to-play: its picking starts now.
  def handle_call(:skip_song, _from, %{phase: :intro} = state) do
    {:reply, :ok, broadcast(end_intro(state))}
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
  def handle_call({:host_signing_in, purpose}, _from, state) do
    sign_ins = open_sign_ins(state)

    cond do
      not host_may_sign_in?(state) ->
        {:reply, {:error, :no_host_screen}, state}

      map_size(sign_ins) >= @max_sign_ins ->
        {:reply, {:error, :too_many_sign_ins}, state}

      true ->
        id = generate_id()
        sign_ins = Map.put(sign_ins, id, now_ms() + sign_in_grace_ms())
        # A finished game waits for a host saving its playlist.
        state =
          if purpose == :playlist, do: keep_finished(state, sign_in_grace_ms()), else: state

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

  def handle_info({:intro_done, si}, %{phase: :intro, subround_index: si} = state) do
    {:noreply, broadcast(end_intro(state))}
  end

  # Each clip's timer names its song, so one that fired as a song_ended
  # call started the next clip doesn't cut that one short too.
  def handle_info({:vs_next, si, ri, side}, state) do
    if state.phase == :playing and state.round_state == :voting and
         match?(%{style: :vs, clips_done?: false, playing: ^side}, state.round) and
         state.subround_index == si and state.round_index == ri do
      {:noreply, broadcast(vs_next(state))}
    else
      {:noreply, state}
    end
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

  defp try_start(state) do
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

  # Connecting a service picks that service's default background track, unless
  # the host's pick is already one of its songs, or they turned the music off
  # (and this is only a refresh of the same service's token).
  defp with_background(state, mod, previous_provider) do
    cond do
      state.host.background && mod.valid_uri?(state.host.background.uri) ->
        state

      state.host.background_off? and previous_provider == mod.id() ->
        state

      true ->
        put_host(state, background: Music.default_background(mod), background_off?: false)
    end
  end

  defp put_host(state, changes), do: %{state | host: Enum.into(changes, state.host)}

  defp start_game(state) do
    player_ids = player_ids(state)
    config = seated_config(state.overrides, length(player_ids))

    subrounds = Enum.flat_map(state.themes, &build_subrounds(&1, config, player_ids))

    state = %{
      state
      | config: config,
        subrounds: subrounds,
        subround_index: 0,
        picking: %{started_ms: nil, finished: %{}, times: %{}},
        ending: %{finale: nil, saved_playlist: nil, until_ms: nil},
        scores: reset_scores(state)
    }

    begin_subround(state, 0)
  end

  # One sub-round per style of the theme when enabled; a single all-styles
  # sub-round when not. The styles follow the theme's style_sequence.
  defp build_subrounds(theme, config, player_ids) do
    ordered_styles = Enum.uniq(theme.style_sequence)
    pools = Map.new(ordered_styles, &{&1, Content.game_questions(theme.id, &1)})

    # Head to head is always a sub-round of its own, in its place in the
    # sequence; collapsed, the other styles around it share one.
    groups =
      if config.subrounds_enabled? do
        Enum.map(ordered_styles, &[&1])
      else
        ordered_styles
        |> Enum.chunk_by(&(&1 == :vs))
        |> Enum.flat_map(fn
          [:vs | _] = vs -> Enum.map(vs, &[&1])
          others -> [others]
        end)
      end

    Enum.map(groups, fn group ->
      build_subround(theme.id, group, config, player_ids, Map.take(pools, group))
    end)
  end

  # Head to head: everyone gets the same one prompt, drawn at random.
  defp build_subround(theme_id, [:vs] = styles, _config, player_ids, pools) do
    {assignments, questions_by_id} =
      case pools |> Map.get(:vs, []) |> Enum.shuffle() do
        [] -> {%{}, %{}}
        [question | _] -> {%{question.id => player_ids}, %{question.id => question}}
      end

    %{
      theme_id: theme_id,
      styles: styles,
      assignments: assignments,
      questions_by_id: questions_by_id,
      pools: pools,
      # the entries through to the next stage, in order, and whether the
      # last matchup was a final played to a vote (a skipped final, or one
      # nobody was left to play, crowns nobody)
      bracket: %{advancing: [], played?: false}
    }
  end

  defp build_subround(theme_id, styles, config, player_ids, pools) do
    {assignments, questions_by_id} =
      Enum.reduce(styles, {%{}, %{}}, fn style, {assign_acc, q_acc} ->
        pool = Map.get(pools, style, [])
        assignment = Binning.assign(player_ids, pool, config.questions_per_player)

        by_id = Map.new(pool, fn q -> {q.id, q} end)

        used_questions =
          assignment
          |> Map.keys()
          |> Map.new(fn qid -> {qid, Map.fetch!(by_id, qid)} end)

        {Map.merge(assign_acc, assignment), Map.merge(q_acc, used_questions)}
      end)

    %{
      theme_id: theme_id,
      styles: styles,
      assignments: assignments,
      questions_by_id: questions_by_id,
      pools: pools
    }
  end

  # =========================================================================
  # A round's how-to-play
  # =========================================================================

  # A theme's first sub-round opens with its how-to-play; the theme's later
  # sub-rounds go straight to their picking.
  defp begin_subround(state, index) do
    previous = index > 0 && Enum.at(state.subrounds, index - 1)
    subround = Enum.at(state.subrounds, index)

    if (previous && previous.theme_id == subround.theme_id) or intro_ms() == 0,
      do: begin_answering(state, index),
      else: begin_intro(state, index)
  end

  # The intro's timer is the answer timer's: one of the two runs at a time.
  defp begin_intro(state, index) do
    ms = intro_ms()
    ref = schedule({:intro_done, index}, ms)

    %{
      state
      | phase: :intro,
        round_state: nil,
        subround_index: index,
        submissions: %{},
        answer_deadline_ms: now_ms() + ms,
        answer_window_ms: ms,
        answer_ref: ref,
        rounds: [],
        round_index: 0,
        round: nil,
        vote_deadline_ms: nil
    }
  end

  defp end_intro(state),
    do: state |> cancel_timer(:answer_ref) |> begin_answering(state.subround_index)

  # =========================================================================
  # Answering
  # =========================================================================

  defp begin_answering(state, index) do
    subround = Enum.at(state.subrounds, index)
    # Each style in a sub-round asks `questions_per_player` questions, so the
    # answer window scales with how many styles the sub-round covers (1 for a
    # normal sub-round; S for the collapsed all-styles case).
    # A head-to-head sub-round asks one prompt.
    ms =
      if subround.styles == [:vs],
        do: state.config.answer_s_per_question * 1000,
        else: Config.answer_window_s(state.config) * max(length(subround.styles), 1) * 1000

    ref = schedule({:answer_timeout, index}, ms)

    %{
      state
      | phase: :answering,
        round_state: nil,
        subround_index: index,
        submissions: %{},
        picking: %{state.picking | started_ms: now_ms(), finished: %{}},
        answer_deadline_ms: now_ms() + ms,
        answer_window_ms: ms,
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
    %{state | answer_ref: ref, answer_deadline_ms: now_ms() + ms, answer_window_ms: ms}
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
    state = %{state | picking: %{state.picking | times: add_pick_times(state)}}

    if vs?(state) do
      entries =
        for {{player_id, _qid}, song} <- Enum.shuffle(state.submissions),
            do: %{player_id: player_id, song: song}

      bracket_stage(state, entries)
    else
      begin_playing(%{state | rounds: build_rounds(state), round_index: 0})
    end
  end

  # =========================================================================
  # Head to head
  # =========================================================================

  defp vs?(state), do: current_subround(state).styles == [:vs]

  # A stage of the bracket: its matchups are the rounds; a bye goes straight
  # through. One entry left is the champion, whose picker gets the bonus if
  # the final was played to a vote (not a lone song, a skipped final or a
  # walkover); none, nothing to play.
  defp bracket_stage(state, []), do: advance_subround(state)

  defp bracket_stage(state, [champion]) do
    bonus = Bracket.champion_bonus()

    scores =
      if bracket_played?(state) and Map.has_key?(state.participants, champion.player_id),
        do: Map.update(state.scores, champion.player_id, bonus, &(&1 + bonus)),
        else: state.scores

    advance_subround(%{state | scores: scores})
  end

  defp bracket_stage(state, entries) do
    {pairs, bye} = Bracket.pairs(entries)
    question = current_subround(state).questions_by_id |> Map.values() |> List.first()
    stage = Bracket.stage_name(length(entries))
    rounds = Enum.map(pairs, &vs_round(&1, question, stage))

    state
    |> put_bracket(%{advancing: bye})
    |> Map.merge(%{rounds: rounds, round_index: 0})
    |> begin_playing()
  end

  defp vs_round({a, b}, question, stage) do
    %{
      style: :vs,
      qid: question && question.id,
      question: question,
      stage: stage,
      a: a,
      b: b,
      # which of the two is playing
      playing: "a",
      song: a.song,
      # nobody's song in particular: everyone votes, the pickers too
      submitter_id: nil,
      choices: [%{id: "a", name: a.song.name}, %{id: "b", name: b.song.name}],
      correct_choice: nil,
      votes: %{},
      forecast: nil,
      extended_s: 0,
      extend_taps: %{},
      all_in_cut?: false,
      # the clip playing (%{deadline_ms, duration_ms}) until both have had
      # theirs; then the room's pick plays, and the songs that have ended
      revealed: false,
      clip: nil,
      clips_done?: false,
      ended: [],
      deltas: nil,
      next_ms: nil,
      tally: nil,
      winner: nil
    }
  end

  # Changes to the current sub-round's bracket (`advancing`, `played?`).
  defp put_bracket(state, changes) do
    subrounds =
      List.update_at(state.subrounds, state.subround_index, fn subround ->
        Map.update(subround, :bracket, changes, &Map.merge(&1, changes))
      end)

    %{state | subrounds: subrounds}
  end

  defp advancing(state), do: get_in(current_subround(state), [:bracket, :advancing]) || []

  defp bracket_played?(state), do: get_in(current_subround(state), [:bracket, :played?]) == true

  defp vs_picker?(round, id), do: round.a.player_id == id or round.b.player_id == id

  # The other entry of a matchup a player has left.
  defp vs_opponent(round, id), do: if(round.a.player_id == id, do: round.b, else: round.a)

  # A matchup opens with its vote, and the first song's clip.
  defp begin_matchup(state) do
    %{
      state
      | round_state: :voting,
        votes_open_ms: now_ms(),
        vote_deadline_ms: nil,
        vote_ref: nil
    }
    |> start_clip("a")
  end

  defp start_clip(state, side) do
    state = cancel_timer(state, :vote_delay_ref)
    ms = vs_clip_ms()
    ref = schedule({:vs_next, state.subround_index, state.round_index, side}, ms)
    clip = %{deadline_ms: now_ms() + ms, duration_ms: ms}
    %{state | round: play_side(%{state.round | clip: clip}, side), vote_delay_ref: ref}
  end

  defp play_side(round, side),
    do: %{round | playing: side, song: Map.fetch!(round, side(side)).song}

  # The first song's clip is over (or it ended): the second plays; the
  # second's is over: the room's pick plays, and the clock starts.
  defp vs_next(%{round: %{playing: "a"}} = state), do: start_clip(state, "b")

  defp vs_next(state) do
    state = cancel_timer(state, :vote_delay_ref)

    %{state | round: %{state.round | clip: nil, clips_done?: true}}
    |> play_leader()
    |> start_countdown()
    |> update_countdown()
  end

  # Once both clips are heard, the song with the most votes plays (of those
  # that haven't ended); a tie keeps the one playing.
  defp play_leader(%{round: %{style: :vs, clips_done?: true, revealed: false} = round} = state) do
    side =
      case ["a", "b"] -- round.ended do
        [only] -> only
        [] -> round.playing
        _both -> Bracket.leader(vote_list(round), round.playing)
      end

    %{state | round: play_side(round, side)}
  end

  defp play_leader(state), do: state

  # A song ran out after the clips: the other plays on, and with both over
  # there is nothing left to hear, so the vote closes soon.
  defp vs_song_over(state) do
    round = %{state.round | ended: Enum.uniq([state.round.playing | state.round.ended])}
    state = play_leader(%{state | round: round})

    if state.round.playing in state.round.ended,
      do: countdown_at_most(state, all_voted_countdown_ms(state)),
      else: state
  end

  defp vs_results(state) do
    round = state.round
    tally = Bracket.tally({round.a, round.b}, vote_list(round))
    winner = Bracket.winner(tally, Enum.random(["a", "b"]))
    deltas = {round.a, round.b} |> Bracket.deltas(tally) |> only_participants(state)
    ms = results_pause_ms(state)

    # The song going through plays the reveal out.
    round = %{
      play_side(round, winner)
      | revealed: true,
        clip: nil,
        deltas: deltas,
        tally: tally,
        winner: winner,
        next_ms: now_ms() + ms
    }

    ref = schedule({:results_done, state.subround_index, state.round_index}, ms)

    %{
      state
      | round_state: :results,
        round: round,
        scores: add_deltas(state.scores, deltas),
        results_ref: ref,
        history: vs_played(state.history, round)
    }
    |> put_bracket(%{
      advancing: advancing(state) ++ [Map.fetch!(round, side(winner))],
      # Only a final played to a vote crowns a champion with the bonus.
      played?: round.stage == "Final"
    })
  end

  defp side("a"), do: :a
  defp side("b"), do: :b

  # The songs a matchup played, each once a night, as the playlist and the
  # awards remember a round (nobody fooled, nobody called: no right answer).
  defp vs_played(history, round) do
    vote_ms = for {id, %{role: :player, ms: ms}} <- round.votes, into: %{}, do: {id, ms}

    Enum.reduce([round.a, round.b], history, fn entry, acc ->
      if Enum.any?(acc, &(&1.uri == entry.song.uri and &1.submitter_id == entry.player_id)) do
        acc
      else
        [
          %{
            submitter_id: entry.player_id,
            uri: entry.song.uri,
            song_name: entry.song.name,
            artist: entry.song.artist,
            album_art_url: entry.song.album_art_url,
            fooled: 0,
            called: [],
            missed: [],
            vote_ms: vote_ms,
            blamed?: false,
            split?: false
          }
          | acc
        ]
      end
    end)
  end

  # A matchup skipped before its vote: one song goes through, at random,
  # for no points (and, skipping the final, no champion's bonus).
  defp skip_matchup(%{round: %{style: :vs, revealed: false} = round} = state) do
    put_bracket(state, %{
      advancing: advancing(state) ++ [Enum.random([round.a, round.b])],
      played?: false
    })
  end

  defp skip_matchup(state), do: state

  defp only_participants(deltas, state),
    do: Map.filter(deltas, fn {id, _n} -> Map.has_key?(state.participants, id) end)

  defp add_deltas(scores, deltas) do
    Enum.reduce(deltas, scores, fn {id, delta}, acc ->
      Map.update(acc, id, delta, &(&1 + delta))
    end)
  end

  defp vs_clip_ms, do: env_ms(:vs_clip_ms, @vs_clip_s * 1000)

  # A random share of the submissions (`songs_played_pct`) becomes one round
  # each; unanswered questions are dropped.
  defp build_rounds(state) do
    subround = current_subround(state)
    count = Config.songs_to_play(state.config, map_size(state.submissions))

    state.submissions
    |> Enum.shuffle()
    |> Enum.take(count)
    |> Enum.map(fn {{player_id, qid}, song} ->
      question = Map.fetch!(subround.questions_by_id, qid)
      build_round(state, player_id, qid, question, song)
    end)
  end

  # The moment a player has a song for every prompt they were asked (the
  # first time only: changing a pick afterwards doesn't count against them).
  defp note_finished_picking(state, player_id) do
    done? =
      Enum.all?(current_subround(state).assignments, fn {qid, pids} ->
        player_id not in pids or Map.has_key?(state.submissions, {player_id, qid})
      end)

    if done? and not Map.has_key?(state.picking.finished, player_id) do
      ms = now_ms() - state.picking.started_ms
      put_in(state.picking.finished[player_id], ms)
    else
      state
    end
  end

  # Each asked player's picking time this sub-round, added to their total;
  # one who didn't finish is out of the running for the quickest pick.
  defp add_pick_times(state) do
    asked = current_subround(state).assignments |> Map.values() |> List.flatten() |> Enum.uniq()

    Enum.reduce(asked, state.picking.times, fn pid, acc ->
      case {Map.fetch(state.picking.finished, pid), Map.get(acc, pid, 0)} do
        {{:ok, ms}, total} when is_integer(total) -> Map.put(acc, pid, total + ms)
        _unfinished -> Map.put(acc, pid, :dnf)
      end
    end)
  end

  defp build_round(state, submitter_id, qid, %{style: :guess_who} = question, song) do
    round_map(submitter_id, qid, question, song,
      choices: guess_who_choices(state),
      correct_choice: submitter_id
    )
  end

  defp build_round(state, submitter_id, qid, %{style: :guess_question} = question, song) do
    round_map(submitter_id, qid, question, song,
      choices: guess_question_choices(current_subround(state), qid, question),
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
      # How many seconds the room has added to the song, and when each
      # player last tapped for one.
      extended_s: 0,
      extend_taps: %{},
      # whether the all-in cut to a short countdown has happened
      all_in_cut?: false,
      revealed: false,
      deltas: nil,
      # when the reveal gives way to the next song (or the final scores)
      next_ms: nil
    }
  end

  # The submitter's choice is their forecast; anyone else's is a vote.
  defp record_choice(%{submitter_id: id} = round, %{id: id}, choice, _ms),
    do: %{round | forecast: choice}

  # A vote keeps how long its voter took to first lock in once votes opened,
  # and its place in the order the room locked in (`seq`).
  defp record_choice(round, voter, choice, ms) do
    {first, seq} =
      case Map.fetch(round.votes, voter.id) do
        {:ok, %{ms: first, seq: seq}} -> {first, seq}
        :error -> {ms, System.unique_integer([:monotonic])}
      end

    vote = %{choice: choice, role: voter.role, ms: first, seq: seq}

    %{round | votes: Map.put(round.votes, voter.id, vote)}
  end

  # Everyone who has locked something in: the voters, and the submitter once
  # their forecast is in. Sorted, so where the submitter sits in the list
  # says nothing about whose song it is.
  defp locked_in(%{forecast: nil} = round), do: Enum.sort(Map.keys(round.votes))
  defp locked_in(round), do: Enum.sort([round.submitter_id | Map.keys(round.votes)])

  defp guess_who_choices(state) do
    state
    |> players_ordered()
    |> Enum.map(fn p -> %{id: p.id, name: p.name} end)
  end

  defp guess_question_choices(subround, correct_qid, question) do
    decoys =
      subround.pools
      |> Map.get(question.style, [])
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

    cond do
      round.style == :vs ->
        begin_matchup(state)

      delay_ms == 0 ->
        begin_voting(state)

      true ->
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
  #
  # The cut to the short countdown happens once a round: after it, the clock
  # only moves by the seconds the room asks for (`extend_countdown/2`), which
  # a phone dropping out or a vote changed mustn't take back.
  #
  # A head-to-head matchup's clock waits for both clips, however soon the
  # room is in, and then gives the room's pick a moment of its own.
  defp update_countdown(%{round: %{style: :vs, clips_done?: false}} = state), do: state

  defp update_countdown(state) do
    cond do
      all_eligible_voted?(state) and not state.round.all_in_cut? ->
        state
        |> countdown_at_most(all_in_countdown_ms(state))
        |> then(&%{&1 | round: %{&1.round | all_in_cut?: true}})

      all_eligible_voted?(state) ->
        state

      majority_voted?(state) ->
        start_countdown(state)

      true ->
        state
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

  defp enter_results(%{round: %{style: :vs}} = state),
    do: state |> cancel_timer(:vote_ref) |> vs_results()

  defp enter_results(state) do
    state = cancel_timer(state, :vote_ref)
    round = state.round

    deltas =
      round
      |> scoring_round()
      |> Scoring.score_round(vote_list(round), Config.scoring_opts(state.config))
      |> only_participants(state)

    scores = add_deltas(state.scores, deltas)

    ms = results_pause_ms(state)
    round = %{round | revealed: true, deltas: deltas, next_ms: now_ms() + ms}
    ref = schedule({:results_done, state.subround_index, state.round_index}, ms)

    %{
      state
      | round_state: :results,
        round: round,
        scores: scores,
        results_ref: ref,
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

    player_votes = for {id, %{role: :player} = vote} <- round.votes, do: {id, vote}

    %{
      submitter_id: round.submitter_id,
      uri: round.song.uri,
      song_name: round.song.name,
      artist: round.song.artist,
      album_art_url: round.song.album_art_url,
      fooled: Enum.count(player_votes, fn {_id, vote} -> vote.choice != round.correct_choice end),
      called: called,
      missed: for({id, vote} <- player_votes, vote.choice != round.correct_choice, do: id),
      vote_ms: Map.new(player_votes, fn {id, vote} -> {id, vote.ms} end),
      # The submitter's blame guess came true.
      blamed?: Scoring.forecast_right?(scoring_round(round), vote_list(round)),
      split?: Scoring.split_room?(scoring_round(round), vote_list(round))
    }
  end

  defp advance_round(state), do: state |> cancel_round_timers() |> skip_matchup() |> next_round()

  defp next_round(state) do
    next = state.round_index + 1

    cond do
      next < length(state.rounds) -> enter_round(state, next)
      vs?(state) -> bracket_stage(state, advancing(state))
      true -> advance_subround(state)
    end
  end

  defp advance_subround(state) do
    next = state.subround_index + 1

    if next < length(state.subrounds) do
      begin_subround(state, next)
    else
      finish(state)
    end
  end

  defp finish(state) do
    %{
      state
      | phase: :finished,
        round_state: nil,
        round: nil,
        rounds: [],
        winners: compute_winners(state),
        ending: %{finale: nil, saved_playlist: nil, until_ms: nil}
    }
    |> keep_finished(finished_shutdown_ms())
  end

  # A finished game closes when left alone this long from now, unless it was
  # already to stay up longer: the night's last song, a playlist being saved.
  defp keep_finished(%{phase: :finished, ending: %{until_ms: until}} = state, ms) do
    if is_integer(until) and until >= now_ms() + ms do
      state
    else
      cancel(state.finished_ref)
      ref = schedule(:finished_shutdown, ms)
      %{state | finished_ref: ref, ending: %{state.ending | until_ms: now_ms() + ms}}
    end
  end

  defp keep_finished(state, _ms), do: state

  defp reset_to_lobby(state) do
    state = cancel_all_timers(state)

    %{
      state
      | phase: :lobby,
        round_state: nil,
        config: nil,
        subrounds: [],
        subround_index: 0,
        submissions: %{},
        answer_deadline_ms: nil,
        answer_window_ms: nil,
        rounds: [],
        round_index: 0,
        round: nil,
        vote_deadline_ms: nil,
        winners: nil,
        ending: %{finale: nil, saved_playlist: nil, until_ms: nil},
        picking: %{started_ms: nil, finished: %{}, times: %{}},
        history: [],
        participants: seat_audience(state),
        scores: reset_scores(state),
        last_activity_ms: now_ms()
    }
  end

  # In the lobby, a free seat (more seats, or a player gone) always goes to
  # whoever has waited longest in the audience.
  defp seat_waiting(%{phase: :lobby} = state), do: %{state | participants: seat_audience(state)}
  defp seat_waiting(state), do: state

  # A new game has player seats to fill: whoever watched the last one from the
  # audience (they arrived after it started) takes any that are free, in the
  # order they joined.
  defp seat_audience(state) do
    free = current_config(state).max_players - role_count(state, :player)

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
      theme: theme_view(current_theme(state)),
      themes: Enum.map(state.themes, &theme_view/1),
      music: music_view(state.music),
      background: state.host.background,
      phone_hosts: state.host.phone_hosts,
      config: config_view(state),
      players: players_view(state),
      audience: audience_view(state),
      subround_index: state.subround_index,
      subround_total: length(state.subrounds),
      subround_styles: current_subround_styles(state),
      intro: intro_view(state),
      answering: answering_view(state),
      round: round_view(state),
      scores: state.scores,
      winners: state.winners,
      awards: awards_view(state),
      playlist: playlist_view(state),
      finale: state.ending.finale,
      saved_playlist: state.ending.saved_playlist
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
        uri: &1.uri,
        song_name: &1.song_name,
        artist: &1.artist,
        album_art_url: &1.album_art_url
      }
    )
  end

  defp playlist_view(_state), do: nil

  # Only a finished game has awards to give.
  defp awards_view(%{phase: :finished, history: history} = state) do
    picks =
      for id <- state.order,
          ms = Map.get(state.picking.times, id),
          is_integer(ms),
          do: %{player_id: id, ms: ms}

    history |> Enum.reverse() |> Awards.summarize(picks)
  end

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
  # fooled, how many of their blame guesses came true and how many of their
  # songs split the room, over the rounds that reached a reveal.
  defp recap(%{phase: :finished, history: history}, player_id) do
    own = Enum.filter(history, &(&1.submitter_id == player_id))

    %{
      called: Enum.count(history, &(player_id in &1.called)),
      fooled: Enum.sum_by(own, & &1.fooled),
      blamed: Enum.count(own, & &1.blamed?),
      split: Enum.count(own, & &1.split?)
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
      answer_s_per_question: config.answer_s_per_question,
      vote_timer_s: config.vote_timer_s,
      vote_delay_s: config.vote_delay_s,
      questions_per_player: config.questions_per_player,
      subrounds_enabled?: config.subrounds_enabled?,
      allow_vote_change?: config.allow_vote_change?,
      min_players: config.min_players,
      max_players: config.max_players,
      quick_reveals?: config.quick_reveals?,
      name_non_voters?: config.name_non_voters?,
      show_places?: config.show_places?,
      final_suspense?: config.final_suspense?,
      score_correct?: config.score_correct?,
      score_fooled?: config.score_fooled?,
      score_predictions?: config.score_predictions?,
      score_split?: config.score_split?,
      name_max_length: config.name_max_length,
      songs_played_pct: config.songs_played_pct
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

  # A round's how-to-play: when its picking starts, and which round of the
  # night it is (`round`, of `of`: one per theme).
  defp intro_view(%{phase: :intro} = state) do
    theme = current_theme(state)

    %{
      deadline_ms: state.answer_deadline_ms,
      duration_ms: state.answer_window_ms,
      round: (Enum.find_index(state.themes, &(&1.id == theme.id)) || 0) + 1,
      of: length(state.themes)
    }
  end

  defp intro_view(_state), do: nil

  defp answering_view(%{phase: :answering} = state) do
    %{
      deadline_ms: state.answer_deadline_ms,
      duration_ms: state.answer_window_ms,
      progress: answering_progress(state)
    }
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
    {eligible, locked} = eligible_vote_counts(state)

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
      # The counts are of the connected (someone who locked in and then
      # dropped out is no longer waited for, nor counted as in), so "N of M
      # in" and `all_in?`, the server's own test for the all-in countdown,
      # always agree.
      votes_received: locked,
      voters: locked_in(round),
      eligible_voters: eligible,
      all_in?: eligible > 0 and locked == eligible,
      votes_open_ms: state.votes_open_ms,
      deadline_ms: state.vote_deadline_ms,
      # Seconds the room has added to the song by tapping for more.
      extended_s: round.extended_s,
      # A head-to-head matchup: its two songs, which is playing, and once
      # revealed whose each was and how the vote went (nil otherwise).
      vs: vs_view(round),
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
        # Some players called it and some didn't (worth a point to the
        # picker while `score_split?` is on).
        split?: Scoring.split_room?(scoring_round(round), vote_list(round)),
        correct_choice: round.correct_choice,
        correct_prompt: correct_prompt(round),
        # When this reveal moves on, so a screen can say "next song in…".
        next_ms: round.next_ms
      })
    else
      Map.merge(base, %{
        submitter_id: nil,
        deltas: nil,
        votes: nil,
        forecast: nil,
        split?: nil,
        correct_choice: nil,
        correct_prompt: nil,
        next_ms: nil
      })
    end
  end

  defp round_view(_state), do: nil

  defp vs_view(%{style: :vs} = round) do
    base = %{
      stage: round.stage,
      playing: round.playing,
      a: round.a.song,
      b: round.b.song,
      # how far into each song the TV starts it
      start_ms: @vs_start_s * 1000,
      clip: round.clip,
      clips_done?: round.clips_done?,
      # The vote is public: who backs which song, in the order they locked in.
      ballots: ballots(round)
    }

    if round.revealed,
      do:
        Map.merge(base, %{
          picks: %{"a" => round.a.player_id, "b" => round.b.player_id},
          tally: round.tally,
          winner: round.winner
        }),
      else: Map.merge(base, %{picks: nil, tally: nil, winner: nil})
  end

  defp vs_view(_round), do: nil

  defp ballots(round) do
    by_side =
      round.votes
      |> Enum.sort_by(fn {_id, vote} -> vote.seq end)
      |> Enum.group_by(fn {_id, vote} -> vote.choice end, fn {id, _vote} -> id end)

    %{"a" => Map.get(by_side, "a", []), "b" => Map.get(by_side, "b", [])}
  end

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
  defp public_prompt(%{style: style, question: %{prompt: prompt}})
       when style in [:guess_who, :vs],
       do: prompt

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

  defp join(state, name) do
    role = join_role(state)
    id = generate_id()
    player = %{id: id, name: name, role: role, connected?: true}

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

  # A name as it is kept: trimmed, its runs of whitespace made one space, and
  # cut to the room's limit. Anything but a string is no name at all.
  defp clean_name(name, max) when is_binary(name) do
    name
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, max)
    |> String.trim_trailing()
  end

  defp clean_name(_name, _max), do: ""

  # Everything the room knew about a participant, gone.
  defp forget_participant(state, id) do
    %{
      state
      | participants: Map.delete(state.participants, id),
        order: List.delete(state.order, id),
        scores: Map.delete(state.scores, id),
        submissions: Map.reject(state.submissions, fn {{pid, _qid}, _song} -> pid == id end),
        picking: %{
          state.picking
          | finished: Map.delete(state.picking.finished, id),
            times: Map.delete(state.picking.times, id)
        },
        subrounds: Enum.map(state.subrounds, &unassign(&1, id))
    }
    |> put_host(phone_hosts: List.delete(state.host.phone_hosts, id))
  end

  # A sub-round without the player: their prompts go, and a prompt nobody
  # else was asked goes with them.
  defp unassign(subround, id) do
    assignments =
      subround.assignments
      |> Map.new(fn {qid, pids} -> {qid, List.delete(pids, id)} end)
      |> Map.reject(fn {_qid, pids} -> pids == [] end)

    %{subround | assignments: assignments}
  end

  # Whatever was under way carries on without them.
  defp drop_from_play(%{phase: :answering} = state, _id), do: maybe_end_answering(state)

  # Head to head: a matchup to come with their song is a walkover for the
  # other; theirs in play, unvoted, sends the other through; and their song
  # goes no further if it already went through.
  defp drop_from_play(%{phase: :playing, round: %{style: :vs} = round} = state, id) do
    {played, to_come} = Enum.split(state.rounds, state.round_index + 1)
    {theirs, others} = Enum.split_with(to_come, &vs_picker?(&1, id))

    advancing =
      Enum.reject(advancing(state), &(&1.player_id == id)) ++
        Enum.map(theirs, &vs_opponent(&1, id))

    state =
      %{state | rounds: played ++ others, round: drop_vote(round, id)}
      |> put_bracket(%{advancing: advancing})

    cond do
      vs_picker?(round, id) and not round.revealed ->
        state
        |> cancel_round_timers()
        |> put_bracket(%{advancing: advancing ++ [vs_opponent(round, id)], played?: false})
        |> next_round()

      state.round_state == :voting ->
        state |> play_leader() |> update_countdown()

      true ->
        state
    end
  end

  defp drop_from_play(%{phase: :playing, round: %{}} = state, id) do
    {played, to_come} = Enum.split(state.rounds, state.round_index + 1)

    to_come =
      for round <- to_come, round.submitter_id != id do
        %{round | choices: without_choice(round, id)}
      end

    state = %{state | rounds: played ++ to_come, round: drop_vote(state.round, id)}

    cond do
      state.round.submitter_id == id and not state.round.revealed -> advance_round(state)
      state.round_state == :voting -> update_countdown(state)
      true -> state
    end
  end

  defp drop_from_play(state, _id), do: state

  defp without_choice(%{style: :guess_who, choices: choices}, id),
    do: Enum.reject(choices, &(&1.id == id))

  defp without_choice(round, _id), do: round.choices

  defp drop_vote(%{revealed: true} = round, _id), do: round

  defp drop_vote(round, id) do
    forecast = if round.submitter_id == id, do: nil, else: round.forecast
    %{round | votes: Map.delete(round.votes, id), forecast: forecast}
  end

  defp join_role(state) do
    cond do
      state.phase != :lobby -> :audience
      role_count(state, :player) >= current_config(state).max_players -> :audience
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
      voter_id not in locked_in(state.round) ->
        :ok

      current_config(state).allow_vote_change? ->
        :ok

      true ->
        {:error, :already_voted}
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

  # The theme being played (the first, before the game starts and after it
  # ends).
  defp current_theme(state) do
    theme_id =
      case Enum.at(state.subrounds, state.subround_index) do
        %{theme_id: id} when state.phase in [:intro, :answering, :playing] -> id
        _other -> nil
      end

    Enum.find(state.themes, hd(state.themes), &(&1.id == theme_id))
  end

  # One more second on the clock (on top of what's left), for one tap.
  defp extend_countdown(state, player_id) do
    state = cancel_timer(state, :vote_ref)
    ms = max(state.vote_deadline_ms - now_ms(), 0) + @extend_ms
    ref = schedule({:vote_timeout, state.subround_index, state.round_index}, ms)

    round = %{
      state.round
      | extended_s: state.round.extended_s + div(@extend_ms, 1000),
        extend_taps: Map.put(state.round.extend_taps, player_id, now_ms())
    }

    %{state | round: round, vote_deadline_ms: now_ms() + ms, vote_ref: ref}
  end

  # One of the player's own songs that was played tonight.
  defp own_played_song(state, player_id, uri) do
    Enum.find(state.history, &(&1.submitter_id == player_id and &1.uri == uri))
  end

  defp current_config(state) do
    state.config || seated_config(state.overrides, role_count(state, :player))
  end

  # Never fewer seats than players already seated: a host lowering the cap
  # takes it down to them, not below (and the players needed to start with
  # it, which is never more than the seats).
  defp seated_config(overrides, players) do
    config = Config.build(overrides, max(players, 1))

    if config.max_players >= players do
      config
    else
      overrides
      |> Map.drop([:max_players, "max_players"])
      |> Map.put(:max_players, players)
      |> Config.build(players)
    end
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

  # Everyone's in: the short final countdown, or, head to head, long enough to
  # hear the room's pick.
  defp all_in_countdown_ms(%{round: %{style: :vs}} = state),
    do: max(all_voted_countdown_ms(state), env_ms(:vs_all_in_ms, @vs_all_in_s * 1000))

  defp all_in_countdown_ms(state), do: all_voted_countdown_ms(state)

  defp intro_ms, do: env_ms(:intro_ms, @intro_ms)

  defp finished_shutdown_ms, do: env_ms(:finished_shutdown_ms, @finished_shutdown_ms)

  defp finale_shutdown_ms, do: env_ms(:finale_shutdown_ms, @finale_shutdown_ms)

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
