defmodule WhoseJamWeb.PlayLive do
  @moduledoc """
  Player phone experience: join, submit songs, vote, follow along.

  A pure renderer of the game server's broadcast state. Mount rejoins silently
  from the device-token cookie (set via `PlayerSessionController.claim/2`),
  subscribes to the room PubSub topic, and tracks presence. Every subsequent
  `{:game_state, _}` broadcast triggers a fresh `player_view` fetch so the
  player-scoped `:me` (assignments + own submissions) stays current.

  Reconnection is automatic: LiveView re-runs `mount/3`, which re-derives the
  full UI from the *current* phase — nothing assumes a phase was witnessed.

  While a round's vote is open, the phone of the player who picked the song
  keeps everyone's layout (anything else would give its owner away): they
  lock in through the same buttons, and what they send is their forecast of
  who takes the blame (see `WhoseJam.Game.cast_vote/3`).

  When the game ends (`{:game_ended, reason}`: the host ended it, closed the
  host screen, or it sat idle) the phone says so and offers the way home. A
  finished game keeps its final scores on screen.
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.Game
  alias WhoseJam.Game.{Awards, Standings}
  alias WhoseJamWeb.{PlayerToken, Presence}

  # =========================================================================
  # Mount
  # =========================================================================

  # Longest search query the server accepts (the input allows a quarter as
  # many characters). Longer ones would go to the provider and into the cache.
  @max_query_bytes 400

  @impl true
  def mount(%{"code" => code}, session, socket) do
    socket = assign(socket, default_assigns(code))

    if Game.exists?(code) do
      mount_existing_game(code, session, socket)
    else
      {:ok, assign(socket, status: :missing)}
    end
  end

  defp mount_existing_game(code, session, socket) do
    case valid_token(session, code) do
      {:ok, player_id} ->
        if connected?(socket) do
          Game.rejoin(code, player_id)
          Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
          Presence.track_player(self(), code, player_id)
        end

        socket = socket |> assign(player_id: player_id, status: :joined) |> refresh_view()

        # A phone opened mid-round (a rejoin) goes straight to what is live:
        # the round's opening card is for the room, as it starts, and a
        # phone coming back has no time to spend on it.
        {:ok, assign(socket, skip_card: round_key(socket.assigns.view))}

      :error ->
        {:ok,
         assign(socket, status: :join, joins_audience?: joins_audience?(Game.get_state(code)))}
    end
  end

  # Whether a name entered now joins the audience: the game has started, or
  # every player's seat is taken (the server decides the same way).
  defp joins_audience?(%{phase: phase, players: players}),
    do: phase != :lobby or length(players) >= Game.max_players()

  defp joins_audience?(_view), do: false

  defp default_assigns(code) do
    %{
      code: code,
      status: :loading,
      player_id: nil,
      view: nil,
      me: nil,
      role: nil,
      my_name: nil,
      page_title: "Join",
      # answering
      q_index: 0,
      edit_qid: nil,
      search_query: "",
      search_results: [],
      search_error: nil,
      # {token, timer} of a search waiting its turn (see throttled_search/2)
      search_pending: nil,
      last_search_ms: nil,
      show_times_up: false,
      times_up_dismissed: false,
      # voting
      vote_error: nil,
      # {round, choice}: a name tapped but not yet locked in
      chosen: nil,
      # join
      join_error: nil,
      joins_audience?: false,
      audience_notice: false,
      # an audience member Play again gave a seat to, while the lobby is on
      promoted?: false,
      # the round this phone opened in, whose opening card it doesn't replay
      skip_card: nil,
      # why the game ended, once status is :ended
      end_reason: nil
    }
  end

  # =========================================================================
  # Events
  # =========================================================================

  @impl true
  def handle_event("join", %{"name" => name}, socket) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:noreply, assign(socket, join_error: "Pick a display name first.")}

      String.length(name) > 24 ->
        {:noreply, assign(socket, join_error: "That name’s a little long — keep it under 24.")}

      true ->
        do_join(socket, name)
    end
  end

  # Every search may cost the music service's quota, so only someone who has
  # songs to pick can search (see can_search?/1), and never with a query longer
  # than a song title could need.
  def handle_event("search", %{"q" => q}, socket)
      when is_binary(q) and byte_size(q) <= @max_query_bytes do
    query = String.trim(q)

    cond do
      not can_search?(socket) -> {:noreply, socket}
      query == "" -> {:noreply, clear_search(socket)}
      true -> {:noreply, throttled_search(socket, query)}
    end
  end

  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("clear_search", _params, socket), do: {:noreply, clear_search(socket)}

  def handle_event("pick_song", %{"uri" => uri, "question" => qid} = params, socket)
      when is_binary(uri) and is_binary(qid) do
    song = %{
      uri: uri,
      name: Map.get(params, "name"),
      artist: Map.get(params, "artist"),
      album_art_url: blank_to_nil(Map.get(params, "album"))
    }

    case Game.submit_song(socket.assigns.code, socket.assigns.player_id, qid, song) do
      :ok ->
        socket =
          socket
          |> clear_search()
          |> assign(edit_qid: nil)
          |> refresh_view()

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         assign(socket, search_error: "Couldn’t lock in that pick — the timer may have ended.")}
    end
  end

  def handle_event("pick_song", _params, socket) do
    {:noreply, assign(socket, search_error: "Couldn’t lock in that pick — try it again.")}
  end

  def handle_event("change_pick", %{"question" => qid}, socket) when is_binary(qid) do
    {:noreply, socket |> clear_search() |> assign(edit_qid: qid)}
  end

  def handle_event("change_pick", _params, socket), do: {:noreply, socket}

  # Changing one's mind about changing a pick: the saved one stands.
  def handle_event("keep_pick", _params, socket),
    do: {:noreply, socket |> clear_search() |> assign(edit_qid: nil)}

  def handle_event("next_q", _params, socket) do
    {:noreply, move_question(socket, +1)}
  end

  def handle_event("prev_q", _params, socket) do
    {:noreply, move_question(socket, -1)}
  end

  # One path for everyone, the round's own picker included: what they send is
  # their guess at who the room will blame (the server keeps it apart from the
  # votes), and their phone does exactly what everyone's does.
  def handle_event("vote", %{"choice" => choice}, socket) when is_binary(choice) do
    case Game.cast_vote(socket.assigns.code, socket.assigns.player_id, choice) do
      :ok ->
        {:noreply, socket |> assign(vote_error: nil) |> refresh_view()}

      {:error, :already_voted} ->
        {:noreply, assign(socket, vote_error: "Your vote is already locked in.")}

      {:error, _reason} ->
        {:noreply, assign(socket, vote_error: "Couldn’t record that vote.")}
    end
  end

  def handle_event("vote", _params, socket) do
    {:noreply, assign(socket, vote_error: "Couldn’t record that vote.")}
  end

  # When votes can't be changed, a tap only chooses; "lock" commits it. A
  # stray thumb costs nothing, and a vote is still final once locked in.
  def handle_event("choose", %{"choice" => choice}, socket) when is_binary(choice) do
    {:noreply, assign(socket, vote_error: nil, chosen: {round_key(socket.assigns.view), choice})}
  end

  def handle_event("choose", _params, socket), do: {:noreply, socket}

  def handle_event("lock", _params, socket) do
    case chosen_choice(socket.assigns) do
      nil -> {:noreply, socket}
      choice -> handle_event("vote", %{"choice" => choice}, socket)
    end
  end

  # From the no-game screen: another room code, cleaned up as the home page
  # cleans it.
  def handle_event("try_code", %{"code" => code}, socket) when is_binary(code) do
    case code |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "") |> String.slice(0, 4) do
      "" -> {:noreply, socket}
      clean -> {:noreply, push_navigate(socket, to: ~p"/play/#{clean}")}
    end
  end

  def handle_event("try_code", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_times_up", _params, socket) do
    {:noreply, assign(socket, show_times_up: false, times_up_dismissed: true)}
  end

  # =========================================================================
  # Broadcasts
  # =========================================================================

  @impl true
  def handle_info({:game_state, view}, socket) do
    {:noreply, refresh_view(socket, view)}
  end

  # The game's last word: its server is gone, so keep the last view we had
  # (a finished game's scores) rather than fetching a new one.
  def handle_info({:game_ended, reason}, socket) do
    {:noreply, socket |> cancel_pending_search() |> assign(status: :ended, end_reason: reason)}
  end

  # A throttled search's turn has come. A stale one (superseded or cleared
  # since it was scheduled) no longer matches the pending token and is dropped,
  # and so is one whose answering phase ended while it waited.
  def handle_info({:run_search, token, query}, socket) do
    case socket.assigns.search_pending do
      {^token, _timer} ->
        socket = assign(socket, search_pending: nil)
        {:noreply, if(can_search?(socket), do: run_search(socket, query), else: socket)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # =========================================================================
  # Internals
  # =========================================================================

  defp do_join(socket, name) do
    case Game.join(socket.assigns.code, name) do
      {:ok, %{player_id: player_id, role: role} = result} ->
        token =
          PlayerToken.sign(%{code: socket.assigns.code, player_id: player_id, role: role})

        # The cookie can only be set from a plain controller request, so we do a
        # full navigation through /claim, which persists the token and bounces
        # back to /play/:code (where mount will silently rejoin).
        if Map.get(result, :audience_soft_cap_exceeded) do
          {:noreply,
           socket
           |> put_flash(:info, "The room’s packed — you’re in as audience. You can still vote!")
           |> redirect(to: ~p"/claim/#{token}")}
        else
          {:noreply, redirect(socket, to: ~p"/claim/#{token}")}
        end

      {:error, _reason} ->
        {:noreply, assign(socket, join_error: "Couldn’t join this game. It may have ended.")}
    end
  end

  # Searching is for a joined player while songs are being picked. Audience
  # members never pick songs, and anyone joining after the lobby is audience.
  defp can_search?(%{assigns: %{status: :joined, role: :player, view: %{phase: :answering}}}),
    do: true

  defp can_search?(_socket), do: false

  # The browser debounces typing, but that is only a courtesy: a search can cost
  # the music service's quota (YouTube allows about 100 a day), so the server
  # enforces the same spacing per connection. A search that arrives too soon
  # waits its turn, and only the latest one waiting is run.
  defp throttled_search(socket, query) do
    socket = cancel_pending_search(socket)
    wait_ms = search_wait_ms(socket)

    if wait_ms <= 0 do
      run_search(socket, query)
    else
      token = make_ref()
      timer = Process.send_after(self(), {:run_search, token, query}, wait_ms)
      assign(socket, search_pending: {token, timer})
    end
  end

  defp search_wait_ms(%{assigns: %{last_search_ms: nil}}), do: 0

  defp search_wait_ms(socket) do
    elapsed_ms = System.monotonic_time(:millisecond) - socket.assigns.last_search_ms
    search_debounce(socket.assigns.view) - elapsed_ms
  end

  defp cancel_pending_search(%{assigns: %{search_pending: {_token, timer}}} = socket) do
    Process.cancel_timer(timer)
    assign(socket, search_pending: nil)
  end

  defp cancel_pending_search(socket), do: socket

  # Empty the search box and its results, dropping any search still waiting.
  defp clear_search(socket) do
    socket
    |> cancel_pending_search()
    |> assign(search_query: "", search_results: [], search_error: nil)
  end

  defp run_search(socket, query) do
    socket = assign(socket, last_search_ms: System.monotonic_time(:millisecond))

    case Game.search_songs(socket.assigns.code, query) do
      {:ok, results} ->
        assign(socket, search_query: query, search_results: results, search_error: nil)

      {:error, reason} when reason in [:not_configured, :no_music] ->
        assign(socket,
          search_query: query,
          search_results: [],
          search_error: "Song search isn’t set up on this server right now."
        )

      {:error, :quota_exceeded} ->
        assign(socket,
          search_query: query,
          search_results: [],
          search_error:
            "The music service’s search limit for today is used up, " <>
              "so searching won’t work until it resets."
        )

      {:error, _other} ->
        assign(socket,
          search_query: query,
          search_results: [],
          search_error: "Couldn’t reach the music service — try that search again."
        )
    end
  end

  defp move_question(socket, delta) do
    assigned = assigned_questions(socket.assigns)
    max_index = max(length(assigned) - 1, 0)
    new_index = min(max(socket.assigns.q_index + delta, 0), max_index)

    socket
    |> clear_search()
    |> assign(q_index: new_index, edit_qid: nil)
  end

  # Re-fetch the player-scoped view and recompute derived UI state.
  # `broadcast` is the public view a `{:game_state, _}` carried, if any.
  defp refresh_view(socket, broadcast \\ nil) do
    code = socket.assigns.code
    player_id = socket.assigns.player_id

    case Game.player_view(code, player_id) do
      nil ->
        # The game is gone. A broadcast still queued when it ended gets here,
        # and the `{:game_ended, _}` behind it shows a finished game's scores:
        # keep the newest view there is, that broadcast's or the last one.
        assign(socket, status: :missing, me: nil, view: broadcast || socket.assigns.view)

      %{me: nil} ->
        # Token points at a player the server no longer knows (e.g. a brand-new
        # game under the same code). Fall back to the join form.
        assign(socket, status: :join, view: nil, me: nil, player_id: nil)

      view ->
        me = view.me
        # A fresh answering phase (e.g. a new sub-round) resets the dismissal so
        # a later "time's up" for that sub-round can surface again.
        times_up_dismissed =
          if view.phase == :answering, do: false, else: socket.assigns.times_up_dismissed

        # Watched from the audience, now has a seat (Play again fills free
        # seats from it): the lobby says so until the game starts.
        promoted? =
          view.phase == :lobby and me.role == :player and
            (socket.assigns.promoted? or socket.assigns.role == :audience)

        socket
        |> assign(
          status: :joined,
          view: view,
          me: me,
          role: me.role,
          promoted?: promoted?,
          my_name: participant_name(view, player_id),
          times_up_dismissed: times_up_dismissed,
          show_times_up: compute_times_up(me, view, times_up_dismissed)
        )
    end
  end

  # Server truth beats a witnessed transition: any player whose assigned
  # questions went unsubmitted (`me.missed_count > 0`) once we're past answering
  # sees the notice — including one who only reconnects after answering ended.
  defp compute_times_up(%{role: :player, missed_count: missed}, %{phase: :playing}, false)
       when missed > 0,
       do: true

  defp compute_times_up(_me, _view, _dismissed), do: false

  defp valid_token(session, code) do
    case PlayerToken.seat(session) do
      {:ok, ^code, player_id} -> {:ok, player_id}
      _other -> :error
    end
  end

  # =========================================================================
  # View helpers (pure, read from the assigns/view maps)
  # =========================================================================

  defp assigned_questions(%{me: %{assigned: assigned}}) when is_list(assigned), do: assigned
  defp assigned_questions(_assigns), do: []

  defp current_question(assigns) do
    assigned = assigned_questions(assigns)
    index = min(max(assigns.q_index, 0), max(length(assigned) - 1, 0))
    Enum.at(assigned, index)
  end

  defp answered_count(assigns) do
    assigns |> assigned_questions() |> Enum.count(& &1.submitted?)
  end

  defp participant_name(view, id) do
    (view.players ++ view.audience)
    |> Enum.find(fn p -> p.id == id end)
    |> case do
      nil -> nil
      p -> p.name
    end
  end

  # Server truth: the player-scoped view tells each caller whether the round in
  # play is their own submission (correct even when two players picked the same
  # track).
  defp own_round?(%{me: %{own_round?: own}}), do: own == true
  defp own_round?(_assigns), do: false

  defp my_delta(assigns) do
    Map.get(assigns.view.round.deltas || %{}, assigns.player_id, 0)
  end

  # The scoreboard this device belongs on: players rank among players, the
  # audience among the audience. Equal scores share a place.
  defp board(view, role) do
    participants = if role == :audience, do: view.audience, else: view.players
    Standings.rank(participants, view.scores)
  end

  defp my_row(view, player_id, role) do
    view |> board(role) |> Enum.find(&(&1.id == player_id))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(str), do: str

  # The current song's artwork tints the phone too while a round is on.
  defp current_art(%{phase: :playing, round: %{song: %{album_art_url: url}}})
       when is_binary(url) and url != "",
       do: url

  defp current_art(_view), do: nil

  defp ended_message(:host_ended), do: "That’s the night. Thanks for playing."
  defp ended_message(:host_left), do: "The host closed the game screen, so the game has ended."
  defp ended_message(:idle), do: "This game closed after sitting idle."
  defp ended_message(_reason), do: "This game has ended."

  # =========================================================================
  # Render
  # =========================================================================

  # A screen that stays one phone-width column however wide the device is.
  @narrow "lg:mx-auto lg:w-full lg:max-w-md"

  # A small status pill: the vote clock and what stands in for it.
  @pill "flex shrink-0 items-center gap-1.5 rounded-md px-1 py-1"

  # The same status as plain words across the foot of a waiting screen.
  @bar "flex items-center justify-center gap-1.5 py-3"

  @impl true
  def render(assigns) do
    # Only a game in play tints the phone with its song: not one that has
    # ended mid-song, or gone.
    art_url = if assigns.status == :joined, do: current_art(assigns.view)
    assigns = assign(assigns, art_url: art_url, narrow: @narrow)

    ~H"""
    <%!-- Inside the theme, so a notice wears the game's colours. --%>
    <div data-theme="jam"><Layouts.flash_group flash={@flash} /></div>
    <div
      data-theme="jam"
      class={
        [
          "jam-stage jam-handheld min-h-screen overflow-x-clip",
          # The host’s quick-reveals choice retimes every beat, as on the TV.
          is_map(@view) && @view.config[:quick_reveals?] && "jam-quick"
        ]
      }
    >
      <div :if={@art_url} class="jam-ambient" aria-hidden="true">
        <img src={@art_url} alt="" />
      </div>
      <%!-- A phone's column; a tablet's is the same column a size up (at
           the tablet's 125%, about 36 phone-rems: a bigger phone, never a
           stretched one). --%>
      <div class="mx-auto flex min-h-screen w-full max-w-md flex-col px-5 pb-10 pt-6 lg:max-w-4xl lg:px-10">
        <%= case @status do %>
          <% :missing -> %>
            {missing_screen(assigns)}
          <% :join -> %>
            {join_screen(assigns)}
          <% :joined -> %>
            {joined_screen(assigns)}
          <% :ended -> %>
            {ended_screen(assigns)}
          <% _ -> %>
            <div class="flex flex-1 items-center justify-center text-jam-cream/60">Loading…</div>
        <% end %>
      </div>
    </div>
    """
  end

  # "you", in marker, with an arrow to the name on its left.
  attr :class, :any, default: nil

  defp you_mark(assigns) do
    ~H"""
    <span class={[
      "flex shrink-0 items-center gap-0.5 whitespace-nowrap font-marker text-[0.9375rem] font-bold leading-none text-jam-cream [font-variation-settings:'INFM'_50]",
      @class
    ]}>
      <.marker_stroke
        kind={:arrow}
        class="h-[0.95em] w-[1.6em] [--jam-stroke-w:0.13rem]"
      /> you
    </span>
    """
  end

  # --- top bar --------------------------------------------------------------

  # Who this device is (and, once the game is on, their score) plus the room.
  defp top_bar(assigns) do
    assigns = assign(assigns, my_score: my_score(assigns), my_gain: my_gain(assigns))

    # At the last reveal the header keeps the total it had: the new one is the
    # final scores' to tell.
    assigns =
      if assigns.my_gain > 0 and final_round?(assigns.view) and
           assigns.view.config[:final_suspense?] != false,
         do: assign(assigns, my_score: assigns.my_score - assigns.my_gain, my_gain: 0),
         else: assigns

    ~H"""
    <div class="mb-5 flex items-center justify-between gap-3 short:mb-3">
      <.wordmark class="shrink-0 text-[1.5rem] short:text-[1.3rem]" />
      <div class="flex min-w-0 items-center gap-3">
        <span
          :if={@role == :audience}
          class="jam-chip shrink-0 !bg-jam-orange/15 !px-3 !py-1 text-xs !text-jam-orange"
        >
          Audience
        </span>
        <%!-- Who this is: their name on its tape, and their points beside
             it in the scores' own lettering. --%>
        <%!-- Who this is: their tape, with their points stuck on its end as
             a small orange sticker. --%>
        <span :if={@my_name} id="me" class="flex min-w-0 items-center">
          <.name_tape player_id={@player_id} name={@my_name} class="max-w-[9rem] text-base" />
          <%!-- At a reveal the score waits for the answer, as the TV's does.
               Orange from the first point; none yet is a plain paper sticker,
               as every zero in the game is quieter. --%>
          <span
            :if={@my_score}
            id="my-score"
            class={[
              "jam-sticker relative -ml-1.5 flex shrink-0 items-baseline gap-0.5 px-1.5 py-0.5 leading-none",
              if(@my_score > 0,
                do: "bg-jam-orange text-jam-ink",
                else: "bg-jam-paper text-jam-ink/70"
              )
            ]}
          >
            <span class="grid font-display text-[0.875rem] tabular-nums">
              <span
                :if={@my_gain > 0}
                id={"my-old-score-#{@view.round.index}"}
                class="jam-out jam-beat-3 whitespace-nowrap text-right [grid-area:1/1]"
                aria-hidden="true"
              >
                {@my_score - @my_gain}
              </span>
              <span
                id={"my-new-score-#{@my_gain > 0 && @view.round.index}"}
                class={[
                  "whitespace-nowrap text-right [grid-area:1/1]",
                  @my_gain > 0 && "jam-rise jam-beat-3"
                ]}
                aria-label={score_label(@my_score, @role)}
              >
                {@my_score}
              </span>
            </span>
            <span class="text-[0.8125rem] font-bold" aria-hidden="true">
              {cond do
                @role == :audience -> "right"
                @my_score == 1 -> "pt"
                true -> "pts"
              end}
            </span>
          </span>
        </span>
        <%!-- The room, on a ticket stub, as the TV shows it, until the game
             starts (from then on it is on the TV). --%>
        <span
          :if={!in_play?(@view)}
          class="jam-ticket shrink-0 px-2 py-[0.2rem] font-display text-[0.8125rem] leading-none tracking-[0.06em] [--jam-notch:0.2rem]"
        >
          {@code}
        </span>
      </div>
    </div>
    """
  end

  defp in_play?(%{phase: phase}), do: phase in [:answering, :playing, :finished]
  defp in_play?(_view), do: false

  # The header's points, while a game plays (the final screens' receipt says
  # them instead).
  defp my_score(%{view: %{phase: phase, scores: scores}, player_id: player_id})
       when phase == :playing and is_binary(player_id),
       do: Map.get(scores, player_id, 0)

  defp my_score(_assigns), do: nil

  # A player's points; the audience scores only right guesses, and says so.
  defp score_label(score, :audience), do: "#{score} correct"
  defp score_label(score, _role), do: points(score)

  # The points this player just won, while the round's reveal is on screen.
  defp my_gain(%{view: %{round_state: :results, round: %{deltas: deltas}}, player_id: player_id})
       when is_map(deltas),
       do: Map.get(deltas, player_id, 0)

  defp my_gain(_assigns), do: 0

  # --- game not found -------------------------------------------------------

  defp missing_screen(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col items-center justify-center gap-6 text-center">
      <div>
        <h1 class="font-display text-[1.75rem] leading-tight">No game here</h1>
        <p class="mt-2 text-jam-cream/60">
          There’s no game with the code <span class="font-display tabular-nums text-jam-cream">{@code}</span>. It may have ended.
        </p>
      </div>
      <%!-- A mistyped code is the likeliest reason: try again right here. --%>
      <form
        id="try-code"
        phx-submit="try_code"
        class="flex w-full max-w-xs flex-col gap-3"
      >
        <label for="try-code-input" class="text-sm font-bold text-jam-cream/80">
          Check the code on the TV.
        </label>
        <input
          id="try-code-input"
          type="text"
          name="code"
          autocomplete="off"
          autocapitalize="characters"
          maxlength="4"
          value={@code}
          placeholder="Room code"
          aria-label="Room code"
          class="rounded-full bg-[#2b2a26] px-6 py-4 text-center text-3xl font-extrabold uppercase tracking-[0.3em] text-jam-cream placeholder:normal-case placeholder:tracking-normal placeholder:font-semibold placeholder:text-xl placeholder:text-jam-cream/55 focus:shadow-[inset_0_-0.2rem_0_var(--color-jam-pink)] focus:outline-none"
        />
        <button type="submit" class="jam-btn">Try code</button>
      </form>
      <.link navigate={~p"/"} class="text-sm font-bold text-jam-cream/70 underline underline-offset-4">
        Back home
      </.link>
    </div>
    """
  end

  # --- join form ------------------------------------------------------------

  defp join_screen(assigns) do
    ~H"""
    {top_bar(assigns)}
    <div class={["flex flex-1 flex-col pt-[12vh] short:pt-6", @narrow]}>
      <h1 class="font-display text-4xl leading-tight">Pick a name</h1>
      <%!-- (The room is on the ticket in the header.) --%>
      <p class="mt-2 text-jam-cream/65">The room will see it on every screen.</p>
      <%!-- Said before the name goes in, not after: who this makes you. --%>
      <p
        :if={@joins_audience?}
        id="audience-join-note"
        class="mt-3 rounded-2xl bg-jam-cream/5 px-4 py-3 text-jam-cream/85"
      >
        This game has started, so you’ll join the audience: guess every song, +1 for each one you call.
      </p>

      <form phx-submit="join" class="mt-6 space-y-4">
        <%!-- The name is written straight onto the blank strip of tape it
             will be worn on, in marker; the placeholder is in the body face,
             and focus is a pink line along the strip's foot, inside it, as
             every text field has it. --%>
        <div class="jam-tape jam-cut-0 flex w-full -rotate-[0.6deg] !justify-start !p-0">
          <input
            type="text"
            name="name"
            autocomplete="off"
            autofocus
            maxlength="24"
            placeholder="Your name"
            aria-label="Your name"
            class="h-[3.75rem] w-full min-w-0 bg-transparent px-5 font-marker text-[1.625rem] font-bold leading-none text-jam-ink caret-jam-pink [font-variation-settings:'INFM'_50] placeholder:font-body placeholder:text-lg placeholder:font-semibold placeholder:text-jam-ink/55 focus:shadow-[inset_0_-0.2rem_0_var(--color-jam-pink)] focus:outline-none"
          />
        </div>
        <p :if={@join_error} class="text-sm text-jam-red">{@join_error}</p>
        <button
          type="submit"
          class="jam-btn w-full text-lg"
        >
          {if @joins_audience?, do: "Join the audience", else: "Join game"}
        </button>
      </form>
      <p :if={!@joins_audience?} class="mt-5 text-sm text-jam-cream/60">
        Up to {Game.max_players()} play. Anyone who joins after the game starts votes from the audience.
      </p>
    </div>
    """
  end

  # --- joined: phase dispatch ----------------------------------------------

  defp joined_screen(assigns) do
    ~H"""
    {top_bar(assigns)}
    <%= case {@view.phase, @view.round_state} do %>
      <% {:lobby, _} -> %>
        {lobby_screen(assigns)}
      <% {:answering, _} -> %>
        {answering_screen(assigns)}
      <% {:playing, round_state} -> %>
        {playing_screen(assigns, round_state)}
      <% {:finished, _} -> %>
        {finished_screen(assigns)}
      <% _ -> %>
        <div class="flex flex-1 items-center justify-center text-jam-cream/60">Hang tight…</div>
    <% end %>
    """
  end

  # --- lobby ----------------------------------------------------------------

  defp lobby_screen(assigns) do
    ~H"""
    <%!-- On a phone, one column; on a laptop, the welcome on the left and
         the room (who's here, and how to score) on the right. --%>
    <%!-- On a phone it starts a step under the header that grows with the
         screen but never past 5rem (the rest is at the foot); on a laptop the
         two columns sit in the middle of the screen, the welcome and how to
         score on the left. --%>
    <div class="flex flex-1 flex-col pt-3 before:block before:max-h-20 before:flex-1 md:before:max-h-10 before:content-[''] after:block after:flex-[1.6] after:content-[''] lg:my-auto lg:grid lg:flex-none lg:grid-cols-2 lg:items-start lg:gap-x-12 lg:pb-[6vh] lg:pt-0 lg:before:hidden lg:after:hidden">
      <div>
        <%!-- Straight on the stage, as the TV's lobby is: no card. --%>
        <div>
          <%!-- Their name is in the header and, ringed, among the players
               below; the headline needn't say it a third time. --%>
          <h1 class="font-display text-[2rem] leading-tight">You’re in</h1>
          <p :if={@promoted?} id="promoted" class="mt-1 font-bold text-jam-mint">
            A seat opened up. You’re playing this time.
          </p>
          <p class="mt-1 font-medium text-jam-cream/70">
            <%= if @role == :player do %>
              {lobby_wait(@view)}
            <% else %>
              You’re in the audience: you’ll vote on every song.
            <% end %>
          </p>
          <div class="mt-4 border-t border-jam-cream/10 pt-3">
            <p class="text-sm font-semibold text-jam-cream/65">Tonight’s theme</p>
            <p id="lobby-vibe" class="font-display text-[1.5rem] leading-tight">
              {@view.theme.name}
            </p>
          </div>
        </div>
      </div>
      <%!-- The one rule that changes how you pick: fooling people scores.
           Left-aligned, the +1s in a column, as the TV sets them. --%>
      <div class="lg:col-start-1 lg:row-start-2">
        <ul
          id="how-to-score"
          class="mt-5 space-y-1.5 px-1 text-[0.9375rem] font-medium leading-snug text-jam-cream/80 lg:mt-8"
        >
          <li class="flex gap-3">
            <span class="w-6 shrink-0 font-display text-jam-orange">+1</span>
            <span class="text-pretty">for each correct guess</span>
          </li>
          <li :if={@role == :player} class="flex gap-3">
            <span class="w-6 shrink-0 font-display text-jam-orange">+1</span>
            <span class="text-pretty">for each player your song fools</span>
          </li>
          <li :if={@role == :player} class="flex gap-3">
            <span class="w-6 shrink-0 font-display text-jam-orange">+1</span>
            <span class="text-pretty">for predicting the most popular wrong answer to your song</span>
          </li>
        </ul>
      </div>

      <div class="mt-7 lg:col-start-2 lg:row-span-2 lg:row-start-1 lg:mt-0">
        <h2 class="mb-3 text-sm font-semibold text-jam-cream/65">
          {players_heading(length(@view.players))}
        </h2>
        <%!-- Everyone's name on its strip of tape, as the TV has them. --%>
        <%!-- Their own on a line of its own, pointed out in marker beside it
             as the final scores do; everyone else's under it, in even rows. --%>
        <div
          :for={p <- Enum.filter(@view.players, &(&1.id == @player_id))}
          class="mb-3.5 flex items-center gap-3"
        >
          <.name_tape
            id={"player-#{p.id}"}
            player_id={p.id}
            name={p.name}
            class="jam-pop max-w-full text-xl"
          />
          <.you_mark />
        </div>
        <%!-- (On a tablet, four to a row, as the TV seats them, each seat as
             wide as its name needs; a laptop's narrower column wraps them.) --%>
        <div class="flex flex-wrap gap-x-2.5 gap-y-3 md:grid md:grid-cols-[repeat(4,max-content)] md:justify-between md:gap-y-3.5 lg:flex lg:justify-start">
          <span
            :for={p <- Enum.reject(@view.players, &(&1.id == @player_id))}
            class="relative flex max-w-full items-center"
          >
            <.name_tape
              id={"player-#{p.id}"}
              player_id={p.id}
              name={p.name}
              class="jam-pop max-w-full text-xl"
            />
          </span>
        </div>

        <div :if={@view.audience != []} class="mt-6">
          <h2 class="mb-2 text-sm font-semibold text-jam-cream/65">
            In the audience
          </h2>
          <div class="flex flex-wrap gap-2">
            <span
              :for={p <- @view.audience}
              class={[
                "jam-chip text-sm",
                p.id == @player_id && "jam-chip-on"
              ]}
            >
              {p.name}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp players_heading(1), do: "1 player"
  defp players_heading(n), do: "#{n} players"

  # What the lobby is waiting for: more players, or the host.
  defp lobby_wait(%{players: players, config: %{min_players: min}}) do
    case min - length(players) do
      1 -> "Waiting for 1 more player."
      n when n > 1 -> "Waiting for #{n} more players."
      _ -> "Waiting for the host to start."
    end
  end

  # --- answering ------------------------------------------------------------

  # Safe fallback if the server ever hands us an :answering phase without an
  # answering payload (mirrors HostLive's nil-guarding).
  defp answering_screen(%{view: %{answering: nil}} = assigns) do
    ~H"""
    <div class="flex flex-1 items-center justify-center text-jam-cream/60">
      Getting the next round ready…
    </div>
    """
  end

  defp answering_screen(%{role: :audience} = assigns) do
    assigns = assign(assigns, :ready?, all_picked?(assigns.view))

    ~H"""
    <div class="flex flex-1 flex-col items-center justify-center gap-4 text-center">
      <h1 class="font-display text-[1.75rem] leading-tight">
        {if @ready?, do: "Everyone’s ready", else: "You’re in the audience"}
      </h1>
      <div :if={!@ready?} class="space-y-1">
        <p class="font-medium text-jam-cream">Guess who picked each song. +1 for each you call.</p>
        <p class="text-sm text-jam-cream/70">The game had started when you joined.</p>
      </div>
      <%!-- Only once there is a time to show; it says what it counts down to. --%>
      <div :if={@view.answering && @view.answering.deadline_ms} class="jam-panel mt-2 px-6 py-4">
        <div class="jam-eyebrow">
          {if @ready?, do: "Music starts in", else: "Players are picking songs"}
        </div>
        <div
          id="countdown-answer"
          phx-hook="Countdown"
          data-deadline={@view.answering.deadline_ms}
          class="mt-1 font-display text-3xl tabular-nums text-jam-orange"
        >
          --
        </div>
      </div>
    </div>
    """
  end

  defp answering_screen(assigns) do
    assigned = assigned_questions(assigns)

    assigns =
      assigns
      |> assign(:assigned, assigned)
      |> assign(:total, length(assigned))
      |> assign(:answered, answered_count(assigns))
      |> assign(:question, current_question(assigns))
      |> assign(:index, min(max(assigns.q_index, 0), max(length(assigned) - 1, 0)))

    ~H"""
    <div :if={@total == 0} class="flex flex-1 flex-col items-center justify-center gap-4 text-center">
      <h1 class="font-display text-2xl">Nothing to pick this time</h1>
      <p class="text-jam-cream/60">Hang tight for the music.</p>
    </div>

    <div
      :if={@total > 0}
      class="flex flex-1 flex-col lg:mt-[6vh] lg:grid lg:flex-none lg:grid-cols-2 lg:items-start lg:gap-10"
    >
      <div>
        <%!-- A fixed height, so on a laptop the search box beside it can
             line up with the slip: the words and the clock on a line, the
             clock's bar the line's full width under them. --%>
        <div class="relative mb-4 flex h-8 items-center justify-between gap-3">
          <div class="text-sm font-semibold text-jam-cream/65">
            <%= if @total > 1 do %>
              Prompt {@index + 1} of {@total}, {@answered} picked
            <% else %>
              {if @total == 1 and @answered == 1 and is_nil(@edit_qid),
                do: "Your prompt",
                else: "Pick a song for this prompt"}
            <% end %>
          </div>
          <div :if={!all_picked?(@view)} class="px-1">
            <span
              id="countdown-answer"
              phx-hook="Countdown"
              data-deadline={@view.answering.deadline_ms}
              class="font-display text-[1.375rem] leading-none tabular-nums text-jam-orange"
            >
              --
            </span>
            <div
              :if={@view.answering.deadline_ms}
              id={"answer-bar-#{@view.answering.deadline_ms}"}
              phx-hook="Progress"
              phx-update="ignore"
              data-deadline={@view.answering.deadline_ms}
              data-duration={@view.config.answer_timer_s * 1000}
              class="jam-bar absolute inset-x-0 -bottom-1.5 h-1 overflow-hidden bg-jam-cream/15"
              aria-hidden="true"
            >
              <span class="block h-full origin-left bg-jam-orange [transform:scaleX(1)]"></span>
            </div>
          </div>
        </div>

        <%!-- Once there are songs to choose from, the prompt steps back (a
             smaller line, still all there) so more of them fit. --%>
        <%!-- The prompt's slip, the width of a phone's column (on a laptop,
             only as wide as its words), at one size whether or not there
             are songs to choose from (the line above already says what it
             is). --%>
        <div class="jam-paper jam-lean w-full px-5 py-4 text-jam-ink lg:w-fit lg:max-w-full">
          <%!-- The thing to answer while a song is being picked; once one is
               picked (and not being changed) it is context, said quietly,
               so "You're done" leads. --%>
          <h1 class={[
            "text-pretty",
            if(@question.submitted? and @edit_qid != @question.question_id,
              do: "text-[1.0625rem] font-semibold leading-[1.3]",
              else: "font-display text-[1.5rem] leading-[1.15]"
            )
          ]}>
            {@question.prompt}
          </h1>
        </div>
      </div>

      <%!-- On a laptop, level with the slip (past the line above it). --%>
      <div class="lg:pt-12">
        {answer_body(assigns)}

        <%!-- Only worth showing when there is somewhere to page to. --%>
        <div :if={@total > 1} class="mt-5 flex items-center justify-between">
          <button
            phx-click="prev_q"
            disabled={@index == 0}
            class="jam-btn jam-btn-ghost text-xs !px-4 !py-3 disabled:opacity-30"
          >
            ← Prev
          </button>
          <div class="flex gap-1.5">
            <span
              :for={{q, i} <- Enum.with_index(@assigned)}
              class={[
                "size-2.5 rounded-full",
                i == @index && "bg-jam-pink",
                i != @index && q.submitted? && "bg-jam-mint",
                i != @index && not q.submitted? && "bg-jam-cream/20"
              ]}
            />
          </div>
          <button
            phx-click="next_q"
            disabled={@index >= @total - 1}
            class="jam-btn jam-btn-ghost text-xs !px-4 !py-3 disabled:opacity-30"
          >
            Next →
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp search_placeholder(_view), do: "Search songs or artists…"

  # The search box's character limit. The server's limit is in bytes
  # (@max_query_bytes) and allows four per character.
  defp max_query_length, do: div(@max_query_bytes, 4)

  # How long to wait after the last keystroke before searching: the room's
  # music service says (services with scarce search quota ask for longer).
  defp search_debounce(%{music: %{search_debounce_ms: ms}}) when is_integer(ms), do: ms
  defp search_debounce(_view), do: 300

  # The search-or-submitted body for the current question.
  defp answer_body(assigns) do
    editing? = not assigns.question.submitted? or assigns.edit_qid == assigns.question.question_id
    assigns = assign(assigns, :editing?, editing?)

    ~H"""
    <div class="mt-5 lg:mt-0">
      <div
        :if={not @editing?}
        id="locked-in"
        class="jam-rise flex flex-col items-start gap-4 text-left"
      >
        <%!-- One headline, left where every screen's is, and the wait
             under it. --%>
        <div class="self-stretch text-left">
          <h2 class="font-display text-[1.75rem] leading-tight">
            {if @answered == @total, do: "You’re done", else: "Song picked"}
          </h2>
          <p
            :if={@answered == @total}
            id="waiting-on"
            class="mt-0.5 text-[0.9375rem] font-medium text-jam-cream/70"
          >
            {waiting_on(@view, @player_id)}
          </p>
          {own_song_explainer(assigns)}
        </div>
        <%!-- The song this player picked, as the room will see it: a poster
             with its title and artist. --%>
        <figure class="jam-paper jam-poster w-[54%] max-w-[13rem] self-center p-2.5 pb-3 text-left text-jam-ink">
          <img
            :if={@question.song.album_art_url}
            src={@question.song.album_art_url}
            alt=""
            class="aspect-square w-full object-cover"
          />
          <div
            :if={!@question.song.album_art_url}
            class="grid aspect-square w-full place-items-center bg-jam-ink/10"
          >
            <.icon name="hero-musical-note-solid" class="size-10 text-jam-ink/40" />
          </div>
          <figcaption class="mt-2 px-0.5">
            <p class="line-clamp-2 font-display text-lg leading-tight">
              {@question.song.name}
            </p>
            <p class="mt-0.5 truncate text-sm font-semibold text-jam-ink/65">
              {@question.song.artist}
            </p>
          </figcaption>
        </figure>
        <%!-- A second thought, so a button its words' size, under the
             poster it would change. --%>
        <button
          phx-click="change_pick"
          phx-value-question={@question.question_id}
          class="jam-btn jam-btn-ghost mt-1 self-center px-6 text-base"
        >
          Change pick
        </button>
      </div>

      <div :if={@editing?}>
        <%!-- While another song is looked for, the saved one stays in view:
             it still counts until a new one is picked. --%>
        <div
          :if={@question.submitted?}
          id="current-pick"
          class="mb-3 flex items-center gap-3 rounded-xl bg-jam-night p-3 ring-1 ring-inset ring-jam-cream/12"
        >
          <img
            :if={@question.song.album_art_url}
            src={@question.song.album_art_url}
            alt=""
            class="size-12 shrink-0 rounded-lg object-cover"
          />
          <div class="min-w-0 flex-1">
            <div class="text-xs font-semibold text-jam-cream/60">
              Your pick so far
            </div>
            <div class="truncate font-semibold">{@question.song.name}</div>
          </div>
          <button
            type="button"
            phx-click="keep_pick"
            class="jam-btn jam-btn-ghost shrink-0 !px-4 !py-2 text-sm"
          >
            Keep it
          </button>
        </div>
        <%!-- phx-submit too: without it, Enter submits the form natively and
             reloads the page. --%>
        <form id="song-search-form" phx-change="search" phx-submit="search" class="relative mt-1">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-4 top-[0.95rem] size-6 text-jam-cream/60"
          />
          <input
            type="text"
            name="q"
            value={@search_query}
            maxlength={max_query_length()}
            autocomplete="off"
            phx-debounce={search_debounce(@view)}
            placeholder={search_placeholder(@view)}
            aria-label="Search for a song"
            class="peer w-full rounded-full bg-[#2b2a26] py-4 pl-12 pr-5 font-medium text-jam-cream placeholder-jam-cream/70 focus:shadow-[inset_0_-0.2rem_0_var(--color-jam-pink)] focus:outline-none"
          />
          <%!-- From the first letter typed: the search is on its way (the
               server waits for typing to pause before it searches). --%>
          <p
            id="searching"
            class={[
              "mt-3 hidden text-center text-sm text-jam-cream/60 phx-change-loading:block",
              @search_query == "" && @search_results == [] &&
                "peer-[:not(:placeholder-shown)]:block"
            ]}
          >
            Searching…
          </p>
        </form>

        <p :if={@search_error} class="mt-3 rounded-xl bg-rose-500/10 px-4 py-3 text-sm text-rose-200">
          {@search_error}
        </p>

        <div class="mt-3 space-y-2">
          <button
            :for={track <- @search_results}
            phx-click="pick_song"
            phx-value-uri={track.uri}
            phx-value-name={track.name}
            phx-value-artist={track.artist}
            phx-value-album={track.album_art_url}
            phx-value-question={@question.question_id}
            class="flex w-full items-center gap-3 rounded-2xl bg-jam-night p-2.5 pr-3 text-left transition-colors hover:bg-[#30302c] active:bg-[#363632]"
          >
            <img
              :if={track.album_art_url}
              src={track.album_art_url}
              alt=""
              class="size-12 shrink-0 rounded-lg object-cover"
            />
            <div
              :if={!track.album_art_url}
              class="flex size-12 shrink-0 items-center justify-center rounded-lg bg-jam-cream/10"
            >
              <.icon name="hero-musical-note-solid" class="size-6 text-jam-cream/60" />
            </div>
            <div class="min-w-0 flex-1">
              <div class="line-clamp-2 font-bold leading-snug">{track.name}</div>
              <div class="truncate text-sm text-jam-cream/60">{track.artist}</div>
            </div>
            <%!-- The whole row is the button; this only says so, quietly, so
                 a list of results isn't a column of pink buttons. --%>
            <span class="shrink-0 rounded-md bg-jam-cream px-3.5 py-1.5 text-sm font-extrabold text-jam-ink">
              Pick
            </span>
          </button>
        </div>

        <div
          :if={@search_results == [] and @search_query != "" and is_nil(@search_error)}
          id="no-matches"
          class="mt-3 text-center"
        >
          <p class="text-base text-jam-cream">No songs found for “{@search_query}”.</p>
          <p class="mt-1 text-sm text-jam-cream/70">Try a song title or an artist.</p>
          <button
            type="button"
            id="clear-search"
            phx-click="clear_search"
            class="mt-3 rounded-lg border-2 border-jam-cream/30 px-4 py-2 text-sm font-bold text-jam-cream"
          >
            Clear search
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Said once to everyone, while they wait for the others to pick: what their
  # phone will do when their own song comes up, so the small print then is a
  # reminder and not a surprise.
  defp own_song_explainer(assigns) do
    ~H"""
    <%!-- Right under the wait, in the reading order, not below the fold:
         what this player will do when their own song comes up. --%>
    <p
      :if={not @editing? and @answered == @total}
      id="own-song-explainer"
      class="mt-3 text-base leading-[1.4] text-jam-cream/85"
    >
      <.inline_points text="When your song plays, predict the most popular wrong answer. +1 if you’re right." />
    </p>
    """
  end

  defp all_picked?(%{answering: %{progress: progress}}),
    do: Enum.all?(progress, fn {_id, p} -> p.submitted >= p.total end)

  defp all_picked?(_view), do: false

  # Once this player is done, how many of the others the room is waiting on.
  defp waiting_on(%{answering: %{progress: progress}}, player_id) do
    others =
      Enum.count(progress, fn {id, p} -> id != player_id and p.submitted < p.total end)

    case others do
      0 -> "Everyone’s done. Here comes the music."
      1 -> "Waiting for 1 more player."
      n -> "Waiting for #{n} more players."
    end
  end

  defp waiting_on(_view, _player_id), do: nil

  # --- playing (revealing / voting / results) -------------------------------

  # Safe fallback if a round hasn't materialised yet (mirrors HostLive).
  defp playing_screen(%{view: %{round: nil}} = assigns, _round_state) do
    ~H"""
    <div class="flex flex-1 items-center justify-center text-jam-cream/60">
      Loading the next song…
    </div>
    """
  end

  # The song and its prompt stay put at the top (on a laptop, the left) for the
  # whole round; what to do right now sits below (or beside) them.
  defp playing_screen(assigns, round_state) do
    assigns =
      assigns
      |> assign(:round, assigns.view.round)
      |> assign(:round_state, round_state)

    ~H"""
    <%!-- The same card, for the same time, as the TV's: the phone doesn't
         show the next song while the TV is still announcing the round. --%>
    <div
      :if={@round_state == :revealing and round_key(@view) != @skip_card}
      id={"round-card-#{@view.subround_index}-#{@round.index}"}
      class={[
        "jam-round-card pointer-events-none fixed inset-0 z-10 grid place-items-center bg-jam-ink px-8",
        quick_card?(@round) && "jam-round-card-short"
      ]}
      aria-hidden="true"
    >
      <%!-- The TV's card, phone-sized: the prompt's slip, large, with the
           round as its label (or the round alone, without a prompt). --%>
      <div class="jam-round-card-text flex max-w-xl flex-col items-center gap-5 text-center">
        <p :if={!@round.prompt} class="font-display text-4xl">
          Round {@round.index + 1} <span class="text-jam-cream/40">of {@round.total}</span>
        </p>
        <p :if={@round.prompt} class="text-base font-semibold text-jam-cream/70">
          Round {@round.index + 1} of {@round.total}<span :if={second_take?(@round)}>: another song for</span>
        </p>
        <div
          :if={@round.prompt}
          class="jam-paper jam-lean px-6 pb-5 pt-5 text-jam-ink"
        >
          <p class="font-display text-[1.75rem] leading-[1.15] text-balance">{@round.prompt}</p>
          <%!-- The round's one clue, said here, once. --%>
          <p :if={take_label(@round)} class="mt-3 text-sm font-semibold text-jam-ink/75">
            {take_label(@round)}
          </p>
        </div>
      </div>
    </div>
    <%!-- Every state of a round starts at the same place under the header,
         the song and its prompt fixed at the top, so only what is below
         them changes from listening to voting to the reveal. --%>
    <%!-- A short laptop starts the round right under the header, so the
         poster has as much room under it as beside it. --%>
    <div class="flex flex-1 flex-col pt-1 lg:mt-[6vh] lg:grid lg:flex-none lg:grid-cols-2 lg:items-start lg:gap-10 lg:short:mt-0">
      <div>
        <div
          :if={@show_times_up}
          class="mb-4 flex items-start gap-2 rounded-2xl bg-jam-orange/15 px-4 py-3 text-sm text-jam-orange"
        >
          <.icon name="hero-exclamation-triangle-solid" class="size-5 shrink-0" />
          <span class="flex-1">Time ran out, so your unpicked prompts sit this game out.</span>
          <button phx-click="dismiss_times_up" aria-label="Dismiss">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <%!-- A short screen gets the song as a line instead of a row with
             its cover, for the whole round, so the prompt, the names and the
             lock-in button all fit and nothing above them moves from one
             part of the round to the next. --%>
        <%!-- The song's header for the round, but not while its poster is
             on screen below: the song is never shown twice. --%>
        <%!-- While the song's poster has the screen the row keeps its place
             (the round, at the row's height), so nothing below it moves
             when the vote opens. --%>
        <p
          :if={@round_state == :revealing}
          id="song-line"
          class="mb-3 flex h-12 items-center text-sm font-semibold text-jam-cream/65 short:h-10"
        >
          Round {@round.index + 1} of {@round.total}
        </p>
        <div :if={@round_state != :revealing}>{now_playing(assigns)}</div>

        <%!-- Guess-who rounds say what the song was picked for: the slip the
             game hands round (the TV's, smaller, under the headline that
             heads this screen), sized to its words. The round's one clue
             is pencilled in its margin. --%>
        <figure
          :if={@round.prompt}
          id="round-prompt"
          class="jam-paper jam-lean mt-3 w-full px-3.5 py-2.5 text-jam-ink short:mt-2"
        >
          <%!-- A strip the width of the screen, under the song: what it was
               picked for. The round card gave it its moment in large type;
               here it is context, said quietly in the body face, so the
               task under it leads. --%>
          <blockquote class="text-base font-semibold leading-[1.25] text-pretty">
            {no_widow(@round.prompt)}
          </blockquote>
        </figure>
        <%!-- On a laptop the left column has the room for the song itself:
             its poster, as the TV shows it, under the prompt, in the same
             place for the whole round (listening included), with the meter
             on its art while it plays. --%>
        <figure
          class="jam-paper jam-poster mt-6 hidden w-[13rem] p-2.5 pb-3 text-jam-ink lg:block lg:short:mt-4 lg:short:w-[12rem]"
          aria-hidden="true"
        >
          <div class="relative">
            <img
              :if={@round.song.album_art_url}
              src={@round.song.album_art_url}
              alt=""
              class="aspect-square w-full object-cover"
            />
            <div
              :if={!@round.song.album_art_url}
              class="grid aspect-square w-full place-items-center bg-jam-ink/10"
            >
              <.icon name="hero-musical-note-solid" class="size-12 text-jam-ink/40" />
            </div>
            <span
              :if={@round_state in [:revealing, :voting]}
              class="absolute bottom-2 left-2 flex bg-jam-ink/80 px-1.5 py-1"
            >
              <.now_playing_meter class="text-xs" />
            </span>
          </div>
          <figcaption class="mt-2 px-0.5">
            <p class="line-clamp-2 font-display text-lg leading-tight">{@round.song.name}</p>
            <p class="mt-0.5 truncate text-sm font-semibold text-jam-ink/65">
              {@round.song.artist}
            </p>
          </figcaption>
        </figure>
      </div>

      <%!-- On a laptop, while the song plays, what to do sits level with
           the middle of the slip and poster beside it. --%>
      <div class={[
        "flex flex-1 flex-col lg:flex-none",
        @round_state == :revealing && "lg:self-center"
      ]}>
        <%= case @round_state do %>
          <% :revealing -> %>
            {revealing_body(assigns)}
          <% :voting -> %>
            {voting_body(assigns)}
          <% :results -> %>
            {results_body(assigns)}
          <% _ -> %>
            <div class="mt-6 text-center text-jam-cream/60">…</div>
        <% end %>
      </div>
    </div>
    """
  end

  # A round's card holds long enough to read a prompt the room hasn't seen;
  # with nothing new to read (no prompt on it, or the one the last round had)
  # it is a quicker beat. The TV's card keeps the same time.
  defp quick_card?(%{index: 0}), do: false
  defp quick_card?(%{prompt: nil}), do: true
  defp quick_card?(%{prompt_take: %{back_to_back?: true}}), do: true
  defp quick_card?(_round), do: false

  # How many songs were picked for this round's prompt, and which this is.
  defp take_label(%{prompt_take: %{nth: 1, of: of}}), do: "#{of} songs picked for this prompt"
  defp take_label(%{prompt_take: %{nth: 2, of: 2}}), do: "the other song picked for this prompt"

  defp take_label(%{prompt_take: %{nth: nth, of: of}}),
    do: "song #{nth} of #{of} picked for this prompt"

  defp take_label(_round), do: nil

  # Not the first song picked for its prompt.
  defp second_take?(%{prompt_take: %{nth: nth}}), do: nth > 1
  defp second_take?(_round), do: false

  defp now_playing(assigns) do
    ~H"""
    <%!-- At least the height of the listening line it follows, so the slip
         under it never moves. --%>
    <div id="now-playing" class="flex min-h-12 items-center gap-3 short:min-h-10">
      <%!-- The cover, keyed by round, so a new round never shows the last
           one's cover. (On a laptop the poster beside it says all this, so
           the row keeps only the round and the clock.) --%>
      <div class="relative shrink-0 lg:hidden">
        <img
          :if={@round.song.album_art_url}
          id={"art-#{@round.index}-#{@view.subround_index}"}
          src={@round.song.album_art_url}
          alt=""
          class="size-12 rounded-md object-cover shadow-lg short:size-10"
        />
        <div
          :if={!@round.song.album_art_url}
          class="flex size-12 items-center justify-center rounded-md bg-jam-cream/10 short:size-10"
        >
          <.icon name="hero-musical-note-solid" class="size-6 text-jam-cream/60" />
        </div>
      </div>
      <div class="min-w-0 flex-1">
        <div class="text-xs font-semibold text-jam-cream/65">
          Round {@round.index + 1} of {@round.total}
        </div>
        <%!-- The title whole, on two lines if it needs them. --%>
        <div class="line-clamp-2 text-base font-extrabold leading-tight short:text-sm lg:hidden">
          {@round.song.name}
        </div>
        <%!-- While it plays, the meter beside the artist, off the small
             cover (a poster has the room for it on its art). --%>
        <div class="flex min-w-0 items-center gap-2 text-sm text-jam-cream/60 short:text-xs lg:hidden">
          <span class="truncate">{@round.song.artist}</span>
          <.now_playing_meter :if={@round_state == :voting} class="shrink-0 text-[0.7rem]" />
        </div>
      </div>
      <%!-- While the vote is open its clock sits here, out of the way of the
           question; its place is kept before the clock starts, so the
           song's name never reflows. --%>
      <div :if={@round_state == :voting} class="flex min-w-[5.75rem] shrink-0 justify-end">
        {vote_timer(assigns)}
      </div>
    </div>
    <%!-- The vote's length is known, so it is a bar as well, the full width
         of the column under the song, as the listening clock's is (keyed by
         its deadline: the all-in countdown is a new one). Its place is kept
         all round (the listening line keeps it too), so the slip under it
         never moves. --%>
    <div class="mt-2 h-1" aria-hidden="true">
      <div
        :if={@round_state == :voting and @round.deadline_ms != nil and !@round.all_in?}
        id={"vote-bar-#{@round.deadline_ms}"}
        phx-hook="Progress"
        phx-update="ignore"
        data-deadline={@round.deadline_ms}
        data-duration={@view.config.vote_timer_s * 1000}
        class="jam-bar h-1 w-full overflow-hidden bg-jam-cream/15"
      >
        <span class="block h-full origin-left bg-jam-orange [transform:scaleX(1)]"></span>
      </div>
    </div>
    """
  end

  defp revealing_body(assigns) do
    ~H"""
    <div
      id="phone-listening"
      class="jam-rise flex flex-col items-start gap-5 pt-5 text-left short:gap-3 short:pt-3 lg:pt-0"
    >
      <%!-- What to do first, in the headline's place (where "Whose jam is
           this?" will be), and how long until voting, then the song. --%>
      <div>
        <h1 class="font-display text-[2rem] leading-tight short:text-2xl">Listen up</h1>
        <p id="listen-note" class="mt-0.5 font-medium text-jam-cream/75">
          {if own_round?(assigns),
            do: "Your song. Keep a straight face.",
            else: "It’s playing on the TV."}
        </p>
      </div>
      <%!-- The TV's countdown, in the one form every countdown takes: its
           words and orange numerals on a line, and the square bar under
           them, draining as voting gets nearer. --%>
      <%!-- The numerals at the line's end, so the words before them (the
           picker's are longer) never move them. --%>
      <div class="w-full space-y-2">
        <p class="flex items-baseline justify-between gap-3 text-sm font-medium text-jam-cream/70">
          {if own_round?(assigns), do: "Your prediction opens in", else: "Voting opens in"}
          <span
            id="countdown-votes-open"
            phx-hook="Countdown"
            data-deadline={@round.votes_open_ms}
            class="font-display text-lg tabular-nums text-jam-orange"
          ></span>
        </p>
        <div
          id={"phone-listen-progress-#{@view.subround_index}-#{@round.index}"}
          phx-hook="Progress"
          phx-update="ignore"
          data-deadline={@round.votes_open_ms}
          data-duration={@view.config.vote_delay_s * 1000}
          class="jam-bar h-1.5 overflow-hidden bg-jam-cream/15"
          aria-hidden="true"
        >
          <span class="block h-full origin-left bg-jam-orange [transform:scaleX(1)]"></span>
        </div>
      </div>
      <%!-- The song the TV is playing, as the TV has it: a poster, its cover
           printed on a sheet of paper with its name under it, large enough
           to see at arm's length (`.jam-poster` in app.css). --%>
      <%!-- Under what to do and how long until voting, centred in the column
           (the slip above and the clock run its full width), the song as
           the screen's object. (A laptop has it in the left column already,
           in the same place all round.) --%>
      <figure class="jam-paper jam-poster mt-2 w-[78%] max-w-[16rem] self-center p-3 pb-3.5 text-left text-jam-ink short:max-w-[12rem] short:p-2.5 md:max-w-[19rem] lg:hidden">
        <%!-- The meter on the art's corner, so the artist has the line. --%>
        <div class="relative">
          <img
            :if={@round.song.album_art_url}
            id={"listen-art-#{@round.index}-#{@view.subround_index}"}
            src={@round.song.album_art_url}
            alt=""
            class="aspect-square w-full object-cover"
          />
          <div
            :if={!@round.song.album_art_url}
            class="grid aspect-square w-full place-items-center bg-jam-ink/10"
            aria-hidden="true"
          >
            <.icon name="hero-musical-note-solid" class="size-12 text-jam-ink/40" />
          </div>
          <span class="absolute bottom-2 left-2 flex bg-jam-ink/80 px-1.5 py-1">
            <.now_playing_meter class="text-xs" />
          </span>
        </div>
        <figcaption class="mt-2.5 px-0.5">
          <p class="line-clamp-2 break-words break-keep font-display text-xl leading-tight">
            {@round.song.name}
          </p>
          <p class="mt-0.5 line-clamp-2 text-base font-medium leading-[1.2] text-balance text-jam-ink/70 short:text-[0.9375rem]">
            {@round.song.artist}
          </p>
        </figcaption>
      </figure>
    </div>
    """
  end

  # Every phone has the same layout while a round is on, the picker's
  # included: the same heading place, names, button and locked-in screen, so
  # nothing moves or changes shape to give them away. The picker's job is
  # different (their blame guess: whom the room will wrongly name, for a
  # point), so the words in those places ask them that, headline included.
  # Everyone is also told how this works once, before the first song (see
  # own_song_explainer/1).
  defp voting_body(assigns) do
    picked = assigns.me.vote
    assigns = assign(assigns, picked: picked, own?: own_round?(assigns))

    if not is_nil(picked) and not assigns.view.config.allow_vote_change? do
      assigns =
        assign(assigns, picked_label: choice_label(assigns.round, picked), bar_class: @bar)

      ~H"""
      <%!-- A lock, not a tick: the vote is in, not yet right. The same card
           on every phone; the picker's says what they locked in. --%>
      <.locked_card
        id="phone-voted"
        label={locked_label(@own?)}
        label_id="locked-note"
        name={@picked_label || "Vote locked in"}
        tape_id={@round.style == :guess_who && @picked_label && @picked}
        note="Eyes on the TV"
        class="flex-1"
      >
        <%!-- How the room is getting on, right under where to look (the
             clock is up by the song): the count, then everyone's name,
             taped down once they are in, as the TV shows it. Who is in,
             never what they chose; the picker's phone shows the same. --%>
        <p id="votes-in" class="text-[0.9375rem] font-semibold text-jam-cream/70">
          {votes_in(@round)}
        </p>
        <ul class="mt-3 flex flex-wrap gap-x-2 gap-y-2.5">
          <li :for={p <- @view.players} class="flex">
            <.name_tape
              :if={p.connected? and p.id in @round.voters}
              player_id={p.id}
              name={p.name}
              class="jam-bump gap-1 text-[0.9375rem]"
            >
              <.icon name="hero-check-circle-solid" class="size-4 shrink-0 text-jam-mint-deep" />
            </.name_tape>
            <span
              :if={!(p.connected? and p.id in @round.voters)}
              class="jam-tape-slot text-[0.9375rem]"
            >
              {p.name}
            </span>
          </li>
        </ul>
      </.locked_card>
      """
    else
      change? = assigns.view.config.allow_vote_change?
      chosen = if change?, do: picked, else: chosen_choice(assigns)

      assigns =
        assign(assigns,
          choices: vote_choices(assigns.round, assigns.player_id),
          cols: grid_cols(assigns.round, vote_choices(assigns.round, assigns.player_id)),
          change?: change?,
          chosen: chosen,
          chosen_label: chosen && choice_label(assigns.round, chosen)
        )

      ~H"""
      <%!-- The decision as one block filling the screen under the song:
         the question, then the names on tiles that grow into the room
         there is (up to 4.75rem tall; any more is left at the foot), and
         Lock in a short step under them. The question keeps the headline's
         place, which "Eyes on the TV" and the answer take after it. The same on every phone, the picker's included. --%>
      <div
        id="phone-voting"
        class="mt-5 flex flex-1 flex-col after:block after:grow after:content-[''] short:mt-3 lg:mt-0 lg:after:hidden"
      >
        <%!-- The question is the screen's headline, its how-to right under
             it in a space kept two lines tall on every phone (the picker's
             too), so the names below sit in the same place on every
             screen. The clock is up by the song. --%>
        <h1 class="font-display text-[2rem] leading-tight short:text-2xl">
          {if @change? and @round.all_in?,
            do: "Final changes",
            else: vote_question(@round, @own?)}
        </h1>

        <%!-- What to do stays on screen for the picker after a tap, so the
             task never turns back into an ordinary vote. --%>
        <%!-- The hint and the line that says a choice is saved each keep
             their place from the first tap to the last, so the names below
             never move under a thumb about to tap again. --%>
        <div class="mb-4 mt-1 space-y-1 short:mb-3">
          <%!-- Two lines kept on every phone, the picker's and everyone
               else's alike, so the names under it sit at the same height
               whichever of the two lines wraps (a tablet or laptop has the
               width for either on one). --%>
          <p
            id="vote-hint"
            class="min-h-[2.8em] text-[0.9375rem] font-normal leading-[1.4] text-jam-cream/75 md:min-h-0"
          >
            <.inline_points text={vote_hint(@round, @own?, @change?)} />
          </p>
          <p :if={@change?} class={["text-sm text-jam-mint", !@picked && "invisible"]}>
            {cond do
              @round.all_in? -> "Everyone’s in. Last chance to switch."
              @own? -> "Prediction saved."
              true -> "Vote’s in."
            end}
          </p>
          <p :if={@vote_error} class="text-sm text-jam-red">{@vote_error}</p>
        </div>

        <%!-- Names are short, so they sit two to a row and all fit on a
             small phone; prompts need the full width. They follow the
             question; the button that commits is under the thumb. --%>
        <div class={
          [
            "grid gap-2",
            # Every tile the same size, however long the name on it: a name
            # too long for half the width puts every choice on a row of its
            # own, and a name never wraps (a long one is set a size down).
            # Two to a row on every phone, the smallest too, so the ballot is
            # the same control everywhere.
            # Equal rows, as tall as the names need, then sharing whatever
            # room the screen has left, up to 4rem a row (the grid's cap), so
            # a big phone gets comfortable targets and a small one keeps its
            # names' height; room past the cap is left at the foot. A
            # laptop's grid sits in its column at its names' height.
            # (Names only: a prompt's tile is as tall as its words.)
            "auto-rows-fr",
            @round.style == :guess_who && "grow-[100] basis-0 lg:flex-none",
            @round.style == :guess_who && grid_cap(@choices),
            @cols == 2 && "grid-cols-2"
          ]
        }>
          <button
            :for={choice <- @choices}
            phx-click={if @change?, do: "vote", else: "choose"}
            phx-value-choice={choice.id}
            aria-pressed={to_string(@chosen == choice.id)}
            class={
              [
                "relative min-h-14 min-w-0 rounded-md px-4 py-3 transition-[background-color,transform] duration-150 active:scale-[0.98] short:min-h-12 short:py-2 lg:[@media(max-height:800px)]:min-h-12 lg:[@media(max-height:800px)]:py-2",
                # Names are written as they are on their tapes.
                @round.style == :guess_who &&
                  "flex min-h-[3.75rem] items-center justify-center gap-2 px-9 font-marker font-bold [font-variation-settings:'INFM'_50] short:px-3",
                @round.style == :guess_who && name_size(@choices),
                # Two to a row, an odd one out centred on the last row at a
                # tile's width.
                @cols == 2 &&
                  "last:odd:col-span-2 last:odd:mx-auto last:odd:w-[calc(50%_-_0.25rem)]",
                # A long name takes the whole row rather than breaking.
                @round.style != :guess_who && "pr-11 text-left text-lg font-bold",
                # Chosen, a name becomes its tape (a prompt, a sheet of
                # paper), with a pink tick. It is not yet locked in, so it
                # isn’t pink: solid pink is for the button that commits it.
                @chosen == choice.id && "jam-tile-chosen text-jam-ink",
                @chosen != choice.id && "bg-[#32322e] text-jam-cream hover:bg-[#3a3a35]"
              ]
            }
          >
            <span class={@round.style == :guess_who && "min-w-0 truncate text-center leading-tight"}>
              {if @round.style == :guess_who, do: choice.name, else: choice.prompt}
            </span>
            <.icon
              :if={@chosen == choice.id and @round.style == :guess_who}
              name="hero-check-circle-solid"
              class="size-[0.85em] shrink-0 text-jam-pink"
            />
            <%!-- The chosen one says so with more than its colour: a tick
                 after a name (a prompt's sits at the end of its row, out of
                 the flow, so nothing moves when it appears). --%>
            <.icon
              :if={@chosen == choice.id and @round.style != :guess_who}
              name="hero-check-solid"
              class="absolute right-3.5 top-1/2 size-5 -translate-y-1/2 text-jam-pink"
            />
          </button>
        </div>

        <%!-- The commit, where the thumb already is: right under the names,
             and stuck to the foot of the screen, so it is never below the
             fold. Always there, so the names above never move when one is
             tapped. --%>
        <div :if={!@change?} class="sticky bottom-5 z-10 pt-6">
          <button
            id="lock-vote"
            type="button"
            phx-click="lock"
            disabled={is_nil(@chosen)}
            class="jam-btn w-full text-lg"
          >
            {if @chosen_label, do: "Lock in #{@chosen_label}", else: "Lock in"}
          </button>
        </div>
      </div>
      """
    end
  end

  attr :id, :string, required: true
  attr :icon, :string, default: "hero-lock-closed-solid"
  attr :label, :string, required: true
  attr :name, :string, required: true

  attr :tape_id, :any,
    default: nil,
    doc: "the player the name is, when it is one: the name is then written in and ringed"

  attr :draw?, :boolean, default: true, doc: "draw the ring in (only as the vote is locked)"

  attr :note, :string, default: nil
  attr :note_class, :any, default: nil
  attr :label_id, :string, default: nil
  attr :tag, :string, default: "h1"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  # One screen from the moment a vote is locked in until the answer: a paper
  # ballot with what was picked on it (a player's name written in and ringed
  # in pink marker, as a ballot is marked), its label
  # printed at the top with a small lock (the vote is in, not yet right),
  # where to look next under it, and a line across the foot that is all that
  # changes (how many are in, then the reveal). The picker's is the same
  # ballot with their own label.
  defp locked_card(assigns) do
    ~H"""
    <%!-- The screen's headline in the place the vote's question had (so
         nothing jumps when it changes), left like it; the ballot a step
         under it; then how the room is getting on. --%>
    <div id={@id} class={["flex flex-col text-left", @class]} {@rest}>
      <p
        :if={@note}
        class={[
          "pt-6 short:pt-4",
          @note_class || "font-display text-[2rem] leading-tight short:text-2xl"
        ]}
      >
        {@note}
      </p>
      <%!-- A slip sized to what is on it (its label and the ringed name),
           centred in the column. --%>
      <div class="jam-paper jam-lean mx-auto mt-6 w-fit min-w-[15rem] max-w-full px-8 pb-6 pt-4 text-center text-jam-ink short:mt-4">
        <p
          id={@label_id}
          class="flex items-center justify-center gap-1.5 text-sm font-bold text-jam-ink/60"
        >
          <.icon name={@icon} class="size-4" />
          {@label}
        </p>
        <.dynamic_tag
          tag_name={@tag}
          class={["mt-5 flex justify-center px-1", !@tape_id && "font-display leading-[1.05]"]}
        >
          <span
            :if={@tape_id}
            class={[
              "relative inline-block max-w-full px-[0.55em] py-[0.2em] font-marker font-bold leading-[1.1] [font-variation-settings:'INFM'_50]",
              locked_tape_size(@name)
            ]}
          >
            <span class="block truncate">{@name}</span>
            <.marker_stroke
              kind={:circle}
              class={[
                "absolute inset-0 size-full text-jam-pink [--jam-stroke-w:0.19rem]",
                @draw? && "jam-stroke-draw"
              ]}
            />
          </span>
          <span :if={!@tape_id} class={["line-clamp-3 break-words", locked_name_size(@name)]}>
            {@name}
          </span>
        </.dynamic_tag>
      </div>
      <div class="w-full pb-4 pt-5 short:pt-3">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # A picked player's tape on the ballot, as large as fits.
  defp locked_tape_size(name) do
    case String.length(name) do
      n when n <= 8 -> "text-[2.25rem]"
      n when n <= 13 -> "text-[1.85rem]"
      _ -> "text-[1.4rem]"
    end
  end

  # How many of the round's voters are in, as the TV counts them.
  defp votes_in(%{votes_received: received, eligible_voters: expected})
       when is_integer(received) and is_integer(expected),
       do: "#{received} of #{expected} locked in"

  defp votes_in(_round), do: "votes coming in"

  # The answer as large as it can be on one line of a phone: the screen's
  # headline, as the TV's name is.
  # (A size up on a tablet, which has the room.)
  defp reveal_name_size(name) do
    case String.length(name) do
      n when n <= 5 -> "text-[5.5rem] md:text-[6.5rem]"
      n when n <= 8 -> "text-[4.5rem] md:text-[5.25rem]"
      n when n <= 12 -> "text-5xl md:text-[3.5rem]"
      _ -> "text-[2.5rem] md:text-[2.9rem]"
    end
  end

  # A picked name as large as it can be and still fit the phone: long ones a
  # size or two down, never to the screen's edge.
  defp locked_name_size(name) do
    case String.length(name) do
      n when n <= 10 -> "text-5xl"
      n when n <= 14 -> "text-4xl"
      _ -> "text-3xl"
    end
  end

  # The picker's job, under their own question, in the measure the reveal
  # reports: where most of the wrong guesses land.
  defp vote_hint(_round, true, _change?),
    do: "Predict the most popular wrong answer. +1 if you’re right."

  defp vote_hint(round, false, true), do: "Tap a #{choice_noun(round)}. Tap another to switch."

  defp vote_hint(%{style: :guess_who}, false, false),
    do: "Pick who chose it. +1 if you’re right."

  defp vote_hint(_round, false, false), do: "Pick its prompt. +1 if you’re right."

  # What the round asks: the room, whose song it is; the picker, where the
  # blame will land (see vote_hint/3).
  defp vote_question(%{style: :guess_who}, true), do: "Who’ll get the blame?"
  defp vote_question(_round, true), do: "Which prompt takes the blame?"
  defp vote_question(%{style: :guess_who}, false), do: "Whose jam is this?"
  defp vote_question(_round, false), do: "Which prompt was this for?"

  # What a locked-in screen calls the choice on it.
  defp locked_label(true), do: "Your prediction"
  defp locked_label(false), do: "Locked in"

  # What a round's choices are: players, or prompts.
  defp choice_noun(%{style: :guess_who}), do: "name"
  defp choice_noun(_round), do: "prompt"

  # The name tapped but not yet locked in, if it was in this round.
  defp chosen_choice(%{chosen: {key, choice}} = assigns) do
    if key == round_key(assigns.view), do: choice
  end

  defp chosen_choice(_assigns), do: nil

  defp round_key(%{subround_index: sub, round: %{index: index}}), do: {sub, index}
  defp round_key(_view), do: nil

  # Nobody needs to be offered their own name: a round that asks "whose jam
  # is this?" is never theirs to guess (and the picker only pretends to).
  # Every other player stays on the list all game, in the same place: who has
  # already had a song is for the room to remember, and a list that dimmed
  # them would end by pointing at the answer.
  defp vote_choices(%{style: :guess_who, choices: choices}, player_id),
    do: Enum.reject(choices, &(&1.id == player_id))

  defp vote_choices(%{choices: choices}, _player_id), do: choices

  defp long_names?(choices), do: Enum.any?(choices, &(String.length(&1[:name] || "") > 10))

  # How many names sit to a row: two, or three when there are seven or more
  # short ones (so a full room's names and the button fit a small phone),
  # or one when any is too long for half the width. Prompts take the row.
  defp grid_cols(%{style: :guess_who}, choices),
    do: if(long_names?(choices), do: 1, else: 2)

  defp grid_cols(_round, _choices), do: 1

  # The vote grid's greatest height: 4rem a row (two to a row) and the gaps
  # between. Each a whole class, so the stylesheet has it.
  defp grid_cap(choices) do
    case div(length(choices) + 1, 2) do
      1 -> "max-h-[4rem]"
      2 -> "max-h-[8.5rem]"
      3 -> "max-h-[13rem]"
      4 -> "max-h-[17.5rem]"
      5 -> "max-h-[22rem]"
      6 -> "max-h-[26.5rem]"
      7 -> "max-h-[31rem]"
      _ -> "max-h-[35.5rem]"
    end
  end

  # One size for every name on the grid, set by the longest: names run up to
  # 24 characters and each must fit its tile on one line.
  defp name_size(choices) do
    case choices |> Enum.map(&String.length(&1[:name] || "")) |> Enum.max(fn -> 0 end) do
      n when n <= 16 -> "text-[1.4375rem] short:text-lg"
      n when n <= 20 -> "text-lg"
      _ -> "text-base"
    end
  end

  # What a choice says on its button: a name, or a prompt.
  defp choice_label(%{choices: choices}, choice_id) do
    case Enum.find(choices, &(&1.id == choice_id)) do
      %{name: name} -> name
      %{prompt: prompt} -> prompt
      _ -> nil
    end
  end

  # No countdown until most voters are in; show nothing rather than "--".
  defp vote_timer(%{round: %{deadline_ms: nil}} = assigns), do: ~H""

  # A small pill beside the song while the vote is open: the clock, and once
  # everyone is in, what it now counts down to. It turns orange for the last
  # five seconds.
  defp vote_timer(assigns) do
    assigns = assign(assigns, pill_class: @pill)

    ~H"""
    <div class="flex flex-col items-end">
      <div class={[
        @pill_class,
        "justify-center whitespace-nowrap transition-colors has-[[data-urgent]]:bg-jam-orange has-[[data-urgent]]:text-jam-ink has-[[data-urgent]]:[&_*]:!text-jam-ink"
      ]}>
        <span :if={@round.all_in?} class="text-sm font-bold text-jam-cream/80">Reveal</span>
        <span
          id="countdown-vote"
          phx-hook="Countdown"
          data-deadline={@round.deadline_ms}
          aria-label={if @round.all_in?, do: "Reveal in", else: "Time left"}
          class="font-display text-[1.375rem] leading-none tabular-nums text-jam-orange"
        >
          --
        </span>
      </div>
    </div>
    """
  end

  # The reveal belongs to the room, so the phone sends eyes to the TV while the
  # reveal plays out there (`.jam-beat-1` and `-2` in app.css) and only then
  # shows the answer with what it meant for this player and where they stand.
  defp results_body(assigns) do
    assigns =
      assigns
      |> assign(:own?, own_round?(assigns))
      |> assign(:submitter_name, participant_name(assigns.view, assigns.round.submitter_id))
      |> assign(:outcome, outcome(assigns))
      |> assign(:gain, my_delta(assigns))
      |> assign(:standing, round_standing(assigns))
      |> assign(:guessed, guessed(assigns))
      |> assign(:bar_class, @bar)

    ~H"""
    <div
      id="phone-results"
      class="relative flex flex-1 flex-col gap-6 text-left short:gap-4"
    >
      <%!-- While the TV has the reveal, the phone holds what its owner said,
           so it is never an empty screen. The picker's shows their
           prediction, on the same card as everyone's. --%>
      <%!-- The locked-in screen it follows, unchanged but for its pill. --%>
      <.locked_card
        id={"eyes-up-#{@round.index}"}
        icon={if @guessed, do: "hero-lock-closed-solid", else: "hero-clock-solid"}
        label={if @guessed, do: locked_label(@own?), else: "Time’s up"}
        name={@guessed || "No vote"}
        tape_id={@round.style == :guess_who && @guessed && @me.vote}
        draw?={false}
        note={
          if @guessed,
            do: "Eyes on the TV",
            else: "Time ran out before you #{if @own?, do: "guessed", else: "voted"}."
        }
        note_class={!@guessed && "text-base text-jam-cream/70"}
        tag="p"
        class="jam-out jam-beat-3 absolute inset-0"
        aria-hidden="true"
      />

      <%!-- Whose it was: the name in pink, as on the TV (on their own phone,
           "You"). --%>
      <%!-- In the headline's place (where the question and "Eyes on the TV"
           were), left like them; the result a step under it. On a tablet
           too, straight under the slip: the answer stays with its song, and
           the spare room is under what it says. --%>
      <div
        :if={@round.style == :guess_who}
        class="jam-rise jam-beat-3 jam-after pt-6 short:pt-4 md:pt-9 lg:pt-6"
      >
        <div class="text-lg font-bold text-jam-cream/70">It was…</div>
        <%!-- Underlined in marker, as the TV has it. --%>
        <div class={[
          "relative w-fit max-w-full break-words pb-[0.2em] font-display leading-none text-jam-pink",
          reveal_name_size(if(@own?, do: "You", else: @submitter_name || ""))
        ]}>
          {if @own?, do: "You", else: @submitter_name}
          <.marker_stroke
            kind={:underline}
            class="absolute bottom-0 left-0 h-[0.16em] w-full [--jam-stroke-w:0.2rem]"
          />
        </div>
      </div>
      <div
        :if={@round.style != :guess_who}
        class="jam-rise jam-beat-3 jam-after pt-6 short:pt-4 md:pt-9 lg:pt-6"
      >
        <div class="jam-eyebrow">The prompt was</div>
        <div class="mt-1 font-display text-2xl leading-snug text-jam-pink">
          {@round.correct_prompt}
        </div>
        <div :if={@submitter_name} class="mt-2 text-sm text-jam-cream/60">
          picked by {if @own?, do: "you", else: @submitter_name}
        </div>
      </div>

      <%!-- What the round meant for this player: a sheet of paper, with the
           points it won stuck on as an orange sticker (a round that won
           nothing has none: the sheet says so). --%>
      <div
        id="my-outcome"
        class="jam-rise jam-beat-3 jam-after jam-paper relative w-full bg-jam-cream px-6 pb-5 pt-5 text-jam-ink"
      >
        <span
          :if={@gain > 0}
          class="absolute -right-2.5 -top-3.5 rotate-[7deg] rounded-sm bg-jam-orange px-2.5 py-1 font-display text-2xl leading-none text-jam-ink shadow-[0_0.15rem_0_rgb(0_0_0/0.3)]"
          aria-label={"Plus #{@gain}"}
        >
          +{@gain}
        </span>
        <%!-- The headline says how it went; the sticker says what it was
             worth. --%>
        <%!-- Called it: the headline in a deep mint (mint is "right"); a
             fooling or a miss in ink. The words carry it either way. --%>
        <%!-- In the body face: the revealed name above is the screen's one
             display headline. --%>
        <p class={[
          "text-[1.375rem] font-extrabold leading-tight tracking-[-0.01em] text-balance",
          (@outcome.win? and !@outcome[:bluff?]) && "text-jam-mint-deep"
        ]}>
          {@outcome.headline}
        </p>
        <p
          :if={@outcome.detail}
          class="mt-1.5 text-base font-medium leading-[1.4] text-balance text-jam-ink/75"
        >
          <.points_line text={@outcome.detail} />
        </p>
        <p
          :if={@outcome[:blame]}
          id="my-blame"
          class="mt-0.5 text-base font-medium leading-[1.4] text-balance text-jam-ink/75"
        >
          <.points_line text={@outcome[:blame]} />
        </p>
        <%!-- Where this leaves them: news, so on the result itself. --%>
        <p
          :if={@standing}
          id="my-standing"
          class="mt-3.5 border-t-2 border-dashed border-jam-ink/20 pt-2.5 text-base font-bold text-jam-ink"
        >
          {@standing}
        </p>
      </div>
    </div>
    """
  end

  attr :text, :string, required: true

  # Words with a "+N" in them, the points in orange as every point in the
  # game is (on the dark).
  defp inline_points(assigns) do
    parts =
      for part <- Regex.split(~r/(\+\d+)/, assigns.text, include_captures: true), part != "" do
        {part =~ ~r/\A\+\d+\z/, part}
      end

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span :for={{points?, part} <- @parts} class={points? && "font-bold text-jam-orange"}>{part}</span>
    """
  end

  attr :text, :string, required: true

  # A result line, its points (a leading "+N") in orange as every point in the
  # game is, set in the scores' lettering.
  defp points_line(assigns) do
    assigns =
      case Regex.run(~r/\A(\+\d+)( .*)\z/s, assigns.text) do
        [_, points, rest] -> assign(assigns, points: points, rest: rest)
        _ -> assign(assigns, points: nil, rest: assigns.text)
      end

    ~H"""
    <span :if={@points} class="font-display text-jam-orange-deep">{@points}</span>{@rest}
    """
  end

  # What this phone's owner said this round, as it read on the button: their
  # vote, or the picker's guess at who the room would blame.
  defp guessed(%{round: round, me: %{vote: choice}}) when not is_nil(choice),
    do: choice_label(round, choice)

  defp guessed(_assigns), do: nil

  # What the round meant for the person holding this phone.
  defp outcome(%{round: round} = assigns) do
    delta = my_delta(assigns)

    cond do
      own_round?(assigns) -> submitter_outcome(assigns.view, round, delta)
      is_nil(assigns.me.vote) -> miss("You didn’t vote")
      assigns.me.vote == round.correct_choice -> called(round, delta, assigns.player_id)
      round.style == :guess_who -> fooled(assigns.view, round, assigns.me.vote, assigns.player_id)
      true -> miss("Not the one you picked")
    end
  end

  # Whoever picked the song got this player: say so, with what they said and
  # how much company they have.
  defp fooled(view, round, my_vote, player_id) do
    picker = participant_name(view, round.submitter_id) || "They"

    others =
      Enum.count(
        round.votes || [],
        &(&1.choice != round.correct_choice and &1.voter_id != player_id)
      )

    company =
      case others do
        # Nobody else: the TV says so; the phone doesn't rub it in.
        0 -> ""
        1 -> "1 other was fooled too."
        n -> "#{n} others were fooled too."
      end

    %{
      win?: false,
      headline: "#{picker} got you",
      detail: String.trim("You said #{choice_label(round, my_vote)}. #{company}")
    }
  end

  defp submitter_outcome(view, round, delta) do
    votes = round.votes || []

    wrong = for v <- votes, v.choice != round.correct_choice, into: MapSet.new(), do: v.voter_id

    # In seat order, as the TV names them. Only players can be fooled: an
    # audience guess that missed earns the picker nothing (`Scoring`).
    fooled = for p <- view.players, p.id in wrong, do: p.name

    case {votes, fooled} do
      {[], _} ->
        miss("Nobody voted")

      # A prediction still gets its line: it had nobody to come true on. Not
      # "nobody" when only the audience fell for it (that scores nothing).
      {_, []} ->
        headline =
          if MapSet.size(wrong) > 0, do: "No player fell for it", else: "Nobody fell for it"

        Map.put(miss(headline), :blame, blame_line(round))

      {_, names} ->
        bluff("You fooled #{join_names(names)}", round, delta)
    end
  end

  # A bluff that worked, with what it was worth: the fooling and the blame
  # guess each get a line, so the points add up, and a blame guess that
  # missed says who took the blame instead.
  defp bluff(headline, round, delta) do
    blame = blame_line(round)
    fooling = delta - if(match?(%{forecast: %{right?: true}}, round), do: 1, else: 0)

    %{
      win?: true,
      bluff?: true,
      headline: headline,
      # The fooled are named in the headline; the points line needn't again.
      detail: "+#{fooling} for the bluff",
      blame: blame
    }
  end

  # The TV's sentence: whom the fooled blamed and whether this player called
  # it, led by its point when it scored one (a miss has none).
  defp blame_line(%{forecast: %{choice: choice, right?: right?}} = round) do
    case blamed(round) do
      nil -> "Your prediction: #{guess_name(round, choice)}."
      took when right? -> "+1 " <> prediction(choice, took, true, round)
      took -> prediction(choice, took, false, round)
    end
  end

  defp blame_line(_round), do: nil

  # The TV's words: who took the blame (most of the wrong guesses).
  defp prediction(_choice, took, true, _round),
    do: "for predicting #{join_names(took)}"

  defp prediction(choice, took, false, round),
    do: "Predicted #{guess_name(round, choice)}, but #{join_names(took)} took the blame."

  # A name as it is, a prompt in quotes, as the TV words them.
  defp guess_name(%{style: :guess_who} = round, choice), do: choice_label(round, choice)
  defp guess_name(round, choice), do: "\u201c#{choice_label(round, choice)}\u201d"

  # Whom the fooled players named most (several, when they tie), in words.
  defp blamed(round) do
    wrong =
      for vote <- round.votes || [],
          vote.voter_role == :player and vote.choice != round.correct_choice,
          do: vote.choice

    case Enum.frequencies(wrong) do
      counts when counts == %{} ->
        nil

      counts ->
        top = counts |> Map.values() |> Enum.max()

        counts
        |> Enum.filter(fn {_choice, n} -> n == top end)
        |> Enum.map(fn {choice, _n} -> guess_name(round, choice) end)
        |> Enum.sort()
    end
  end

  # A right guess, and how much company it had.
  defp called(round, delta, player_id) do
    others =
      Enum.count(
        round.votes || [],
        &(&1.choice == round.correct_choice and &1.voter_id != player_id)
      )

    company =
      case others do
        0 -> "Only you got it."
        1 -> "1 other got it too."
        n -> "#{n} others got it too."
      end

    # The points are on the sheet's sticker; the words say who else got it.
    case win("You called it", delta) do
      %{win?: true} = won -> %{won | detail: company}
      missed -> missed
    end
  end

  defp win(headline, delta) when delta > 0,
    do: %{win?: true, headline: headline, detail: "+" <> points(delta)}

  defp win(headline, _delta), do: miss(headline)

  # No points: the sheet has no sticker, and the headline says how it went.
  defp miss(headline), do: %{win?: false, headline: headline, detail: nil}

  defp points(1), do: "1 point"
  defp points(n), do: "#{n} points"

  defp join_names([name]), do: name
  defp join_names([a, b]), do: "#{a} and #{b}"

  defp join_names(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  # "You're tied for 2nd on 5 points", among the players or among the audience.
  # The last round of the game leaves where everyone stands to the TV's final
  # scores, which come next.
  defp round_standing(%{view: view} = assigns) do
    if final_round?(view) and view.config[:final_suspense?] != false,
      do: "Final scores next, on the TV",
      else: standing(view, assigns.player_id, assigns.role)
  end

  defp final_round?(%{round: %{index: index, total: total}} = view),
    do: index + 1 == total and view.subround_index + 1 == view.subround_total

  defp final_round?(_view), do: false

  # Where this player stands, every round, in one pattern ("You're leading",
  # "You're 3rd", "You're tied for 2nd with 3 others"): the place only, as
  # the header already has the points. The audience is ranked among itself,
  # and says so.
  defp standing(view, player_id, role) do
    board = board(view, role)

    case Enum.find(board, &(&1.id == player_id)) do
      nil ->
        nil

      # An audience of one has nobody to be placed among.
      _row when role == :audience and length(board) == 1 ->
        nil

      row ->
        among = if role == :audience, do: " in the audience", else: ""
        "You’re " <> place_line(row, board) <> among <> "."
    end
  end

  defp place_line(row, board) do
    case {row.rank, Enum.count(board, &(&1.rank == row.rank)) - 1} do
      {1, 0} -> "leading"
      {1, _level} -> "tied for the lead"
      {rank, 0} -> Standings.ordinal(rank)
      {rank, _level} -> "tied for #{Standings.ordinal(rank)}"
    end
  end

  defp place(%{rank: rank, tied?: true}), do: "tied for #{Standings.ordinal(rank)}"
  defp place(%{rank: rank}), do: Standings.ordinal(rank)

  # --- finished -------------------------------------------------------------

  # Leads with how this player did, says what happens next, and keeps both
  # above the scores so neither is ever scrolled away. The winner is the TV's
  # to announce, so the phone sends eyes there first and shows its own result
  # a beat behind (`.jam-beat-2` in app.css).
  defp finished_screen(assigns) do
    mine = my_row(assigns.view, assigns.player_id, assigns.role)

    assigns =
      assigns
      |> assign(:board, board(assigns.view, assigns.role))
      |> assign(:players_board, board(assigns.view, :player))
      |> assign(:mine, mine)
      |> assign(:won?, assigns.role == :player and match?(%{rank: 1}, mine))
      |> assign(:playlist, playlist(assigns.view))

    ~H"""
    <div class="relative flex flex-1 flex-col lg:mx-auto lg:w-full lg:max-w-5xl lg:justify-center">
      <%!-- Only while the game is live: once the host has ended it, the
           scores a player is looking at must never go away again. The wait is
           as long as the TV holds back the winner (`.jam-until-winner`). --%>
      <p
        :if={@status == :joined}
        id="final-eyes-up"
        class="jam-out jam-until-winner pointer-events-none fixed inset-0 flex flex-col items-center justify-center gap-2 text-center"
        aria-hidden="true"
      >
        <span class="font-display text-4xl">Eyes on the TV</span>
        <span class="text-base font-medium text-jam-cream/70">Here comes the winner.</span>
      </p>
      <div
        id="final-result"
        class={[
          "flex flex-1 flex-col lg:grid lg:flex-none lg:grid-cols-[minmax(0,1fr)_minmax(0,26rem)] lg:items-start lg:gap-x-12 [&>*]:lg:col-start-1",
          @status == :joined && "jam-rise jam-after-winner"
        ]}
      >
        <%!-- How this player did: who won, then their own finish, then how
             their points came, as numbers with their words under them. --%>
        <%!-- How this player did, on paper like every result, set as a
             receipt: who won, their own finish (the winner's on an orange
             prize tape), then every way the points could come, with a
             dotted leader to each number. --%>
        <%!-- Their place is the headline itself ("You came 2nd"), so the
             receipt carries no second badge saying it again. --%>
        <%!-- The receipt lies all but straight: its dense rows and leaders
             stay level to read. --%>
        <div class="jam-paper relative mt-1 !rotate-[0.3deg] px-4 pb-2.5 pt-2.5 text-jam-ink short:pb-2 short:pt-2">
          <div class="flex items-start gap-4">
            <div class="min-w-0 flex-1">
              <p class="text-sm font-semibold text-jam-ink/65">
                {if @won?, do: "That’s the game", else: winner_line(@players_board)}
              </p>
              <%!-- The winner's line wears its prize: an orange "1st" tape. --%>
              <div class={[
                "flex flex-wrap items-center gap-x-3 gap-y-1",
                if(@won?, do: "mt-4", else: "mt-1")
              ]}>
                <%!-- The winner's phone has its moment: the line larger, and
                     wearing the crown the TV drew on the winner's name, in
                     orange marker (orange type wouldn't read on the paper). --%>
                <h1
                  id="my-place"
                  class={[
                    "relative font-display leading-[1.05] text-balance",
                    if(@won?, do: "text-[2.6rem]", else: "text-[1.75rem]")
                  ]}
                >
                  <.marker_stroke
                    :if={@won?}
                    kind={:crown}
                    class="absolute left-[0.01em] -top-[0.24em] h-[0.52em] w-[0.64em] -rotate-[9deg] text-jam-orange [--jam-stroke-w:0.24rem]"
                  />
                  {if @mine, do: finish_line(@mine, @role, length(@board)), else: "Game over"}
                </h1>
              </div>
            </div>
          </div>
          <dl
            :if={recap_stats(@me, @role, @mine) != []}
            id="my-recap"
            class={
              [
                "space-y-0 border-t-2 border-dashed border-jam-ink/20 pt-1.5 leading-[1.3]",
                # The winner's larger line has a little more room under it.
                if(@won?, do: "mt-3", else: "mt-1.5")
              ]
            }
          >
            <%!-- The total first and largest; how it came, smaller under it. --%>
            <div
              :for={{{value, label}, i} <- Enum.with_index(recap_stats(@me, @role, @mine))}
              class={["flex items-baseline gap-2", i == 0 && "pb-1"]}
            >
              <dt class={[
                if(i == 0,
                  do: "text-base font-bold text-jam-ink",
                  else: "text-[0.9375rem] font-medium text-jam-ink/70"
                )
              ]}>
                {label}
              </dt>
              <span
                class="min-w-4 flex-1 translate-y-[-0.25em] border-b border-dotted border-jam-ink/25"
                aria-hidden="true"
              ></span>
              <%!-- Points are orange, the deeper orange that reads on
                   paper (none, a quiet grey, as on every table). --%>
              <dd class={[
                "font-display leading-none tabular-nums",
                if(value == 0, do: "text-jam-ink/55", else: "text-jam-orange-deep"),
                if(i == 0, do: "text-[1.625rem]", else: "text-lg")
              ]}>
                {value}
              </dd>
            </div>
          </dl>
          <%!-- An award the TV gave this player is theirs to keep here, on
               its orange tape. --%>
          <%!-- Every award the same way, a line each: its title on orange
               tape, and the song it was won with beside it (the counts are
               the receipt's, above). --%>
          <dl :if={my_awards(@view, @player_id) != []} class="mt-3 space-y-1.5">
            <div
              :for={{title, detail} <- my_awards(@view, @player_id)}
              class="flex flex-wrap items-center gap-x-3 gap-y-1"
            >
              <dt class="jam-tape jam-tape-orange jam-tilt-3 text-sm">{title}</dt>
              <dd :if={detail} class="min-w-0 text-[0.9375rem] font-semibold text-jam-ink/80">
                {detail}
              </dd>
            </div>
          </dl>
        </div>

        <%= if @status == :ended do %>
          <%!-- One compact row, so the player's own place in the scores below
               stays on screen however short the screen is. --%>
          <%!-- The room has closed: said plainly, a step up from the
               waiting line it replaces, so nobody misses it. --%>
          <div id="game-ended" class="mt-4 flex flex-col gap-3 px-1">
            <p class="text-[1.0625rem] font-bold text-jam-cream">{ended_message(@end_reason)}</p>
            <.link navigate={~p"/"} class="jam-btn jam-btn-ghost w-fit text-base">
              Back home
            </.link>
          </div>
        <% else %>
          <p id="what-next" class="mt-3 px-1 text-sm font-medium text-jam-cream/65 short:mt-2.5">
            Waiting for the host to start another game.
          </p>
        <% end %>

        <%!-- The night's songs are further down than a glance goes. --%>
        <a
          :if={@playlist != []}
          id="to-playlist"
          href="#my-playlist"
          class="mt-1.5 flex items-center gap-1.5 px-1 text-sm font-bold text-jam-cream/85 underline decoration-jam-cream/30 underline-offset-4 lg:hidden"
        >
          See tonight’s playlist ({songs(length(@playlist))})
          <.icon name="hero-arrow-down-mini" class="size-4" />
        </a>

        <%!-- The game's scores, for everyone; the audience's own after them.
             On a wide screen they have a column of their own, so every row
             (this player's included) is in view without scrolling. --%>
        <div id="final-lists" class="lg:!col-start-2 lg:row-span-6 lg:row-start-1">
          <%= for {title, rows, list_id} <- score_lists(@role, @players_board, @board) do %>
            <h2 class="mb-2 mt-6 px-1 text-sm font-semibold text-jam-cream/65 short:mb-1.5 short:mt-4 lg:mt-0">
              {title}
            </h2>
            <%!-- The audience's table in the TV's words ("4 correct"), with no
               place when there is only one of them. --%>
            <%!-- One table, a row each, with a rule between rows. --%>
            <%!-- The night's setlist: place, name on its tape, score; first
                 place on orange prize tape, a row taller. --%>
            <ol id={list_id} class="jam-panel px-1.5 py-1.5">
              <li
                :for={row <- rows}
                class={[
                  "flex break-inside-avoid items-center justify-between gap-3 rounded-md px-3 leading-tight",
                  if(list_id == "final-scores" and row.rank == 1,
                    do: "min-h-10 py-1 short:min-h-9",
                    else: "min-h-8 py-0.5"
                  ),
                  row.id == @player_id && "bg-jam-cream/[0.08]"
                ]}
              >
                <div class="flex min-w-0 items-center gap-3">
                  <span
                    :if={list_id == "final-scores" or length(rows) > 1}
                    class={[
                      "flex w-[4.75rem] shrink-0 items-baseline gap-1.5 text-[0.9375rem] font-semibold leading-none tabular-nums",
                      if(row.rank == 1, do: "text-jam-orange", else: "text-jam-cream/60")
                    ]}
                  >
                    {Standings.ordinal(row.rank)}
                    <%!-- A shared place says so, beside the place. --%>
                    <span :if={row.tied?} class="font-body text-xs font-semibold">
                      tied
                    </span>
                  </span>
                  <.name_tape
                    player_id={row.id}
                    name={row.name}
                    class={[
                      "max-w-[10rem]",
                      if(list_id == "final-scores" and row.rank == 1,
                        do: "jam-tape-orange text-lg",
                        else: "py-[0.22em] text-[0.9375rem]"
                      )
                    ]}
                  />
                  <.you_mark :if={row.id == @player_id} />
                </div>
                <span
                  :if={list_id == "final-scores"}
                  class={[
                    "font-display text-xl tabular-nums",
                    if(row.score > 0, do: "text-jam-orange", else: "text-jam-cream/50")
                  ]}
                >
                  {row.score}
                </span>
                <span :if={list_id != "final-scores"} class="text-sm font-bold text-jam-cream/80">
                  {row.score} correct
                </span>
              </li>
            </ol>
          <% end %>
        </div>

        <%!-- The night's songs and whose they were: the thing worth keeping,
             in the hand of whoever wants it. --%>
        <div :if={@playlist != []} id="my-playlist">
          <h2 class="mb-2 mt-7 px-1 text-sm font-semibold text-jam-cream/65">
            Tonight’s playlist
          </h2>
          <%!-- A list, not a stack of cards: cover, song, and whose it was. --%>
          <ol class="divide-y divide-jam-cream/[0.07]">
            <li :for={song <- @playlist} class="flex items-center gap-3 py-2 leading-tight">
              <img
                :if={song.album_art_url}
                src={song.album_art_url}
                alt=""
                class="size-11 shrink-0 rounded object-cover"
              />
              <span
                :if={!song.album_art_url}
                class="grid size-11 shrink-0 place-items-center rounded bg-jam-cream/10"
              >
                <.icon name="hero-musical-note-solid" class="size-5 text-jam-cream/60" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate font-bold">{song.song_name}</span>
                <span :if={song.artist} class="block truncate text-sm text-jam-cream/60">
                  {song.artist}
                </span>
              </span>
              <%!-- Whose it was, as their tape. --%>
              <.name_tape
                :if={song.player_id}
                player_id={song.player_id}
                name={song.picked_by}
                class="max-w-[7rem] shrink-0 text-sm"
              />
            </li>
          </ol>
        </div>
      </div>
    </div>
    """
  end

  defp playlist(%{playlist: songs} = view) when is_list(songs) do
    for song <- songs do
      %{
        song_name: song.song_name,
        artist: Map.get(song, :artist),
        album_art_url: blank_to_nil(Map.get(song, :album_art_url)),
        player_id: song.player_id,
        picked_by: participant_name(view, song.player_id) || "someone"
      }
    end
  end

  defp playlist(_view), do: []

  # The player's own game as a receipt: their points, and every way points
  # could come, a zero included, so the card always has the same rows.
  defp recap_stats(%{recap: %{} = recap}, :player, %{score: score}) do
    [
      {score, "Points"},
      {recap.called, "Correct guesses"},
      {recap.fooled, "Players fooled"},
      {Map.get(recap, :blamed, 0), "Correct predictions"}
    ]
  end

  defp recap_stats(_me, _role, _mine), do: []

  defp songs(1), do: "1 song"
  defp songs(n), do: "#{n} songs"

  # Who won, for the cards of everyone who didn't.
  defp winner_line(board) do
    case Enum.filter(board, &(&1.rank == 1)) do
      [] -> "That’s the game"
      [winner] -> "#{winner.name} won"
      winners when length(winners) == length(board) -> "That’s the game"
      [a, b] -> "#{a.name} & #{b.name} share the win"
      winners -> "#{length(winners)} players share the win"
    end
  end

  # Which tables the end screen lists: the game's, and for the audience their
  # own as well.
  defp score_lists(:audience, players_board, board),
    do: [
      {"Final scores", players_board, "final-scores"},
      {"Audience, by correct guesses", board, "audience-scores"}
    ]

  defp score_lists(_role, _players_board, board), do: [{"Final scores", board, "final-scores"}]

  defp finish_line(%{rank: 1, tied?: false}, :player, _count), do: "You won"
  defp finish_line(%{rank: 1, tied?: true}, :player, _count), do: "You tied for the win"
  # An audience of one has nobody to finish ahead of.
  defp finish_line(%{score: 1}, :audience, 1), do: "You called 1 song"
  defp finish_line(%{score: score}, :audience, 1), do: "You called #{score} songs"
  defp finish_line(row, :audience, _count), do: "You finished #{place(row)} in the audience"
  defp finish_line(%{tied?: true} = row, _role, _count), do: "You #{place(row)}"
  defp finish_line(row, _role, _count), do: "You finished #{place(row)}"

  # The awards this player holds, worded as the TV words them, and only the
  # ones the TV hands out (`Awards.given?/1`).
  defp my_awards(%{awards: %{} = awards}, player_id) do
    bluff =
      with %{fooled: fooled, bluffs: bluffs} = award <- awards[:best_bluff],
           true <- Awards.given?(award) do
        my_bluff(for(%{player_id: ^player_id, song_name: song} <- bluffs, do: song), fooled)
      else
        _ -> []
      end

    sharpest =
      with %{called: called, player_ids: ids} = award <- awards[:sharpest],
           true <- Awards.given?(award),
           true <- player_id in ids do
        [{"Sharpest ears", "#{called} right"}]
      else
        _ -> []
      end

    bluff ++ sharpest
  end

  defp my_awards(_view, _player_id), do: []

  defp my_bluff([], _fooled), do: []

  defp my_bluff([song], _fooled), do: [{"Best bluff", song}]
  defp my_bluff(songs, _fooled), do: [{"Best bluff", "#{length(songs)} songs"}]

  # --- game ended -----------------------------------------------------------

  # A finished game keeps its final scores on screen; one that ended earlier
  # (or one this phone never saw) just says so.
  defp ended_screen(%{view: %{phase: :finished}} = assigns) do
    ~H"""
    {top_bar(assigns)}
    {finished_screen(assigns)}
    """
  end

  defp ended_screen(assigns) do
    ~H"""
    {top_bar(assigns)}
    <div id="game-ended" class="flex flex-1 flex-col items-center justify-center gap-6 text-center">
      <div>
        <h1 class="font-display text-[1.75rem] leading-tight">Game over</h1>
        <p class="mt-2 text-jam-cream/60">{ended_message(@end_reason)}</p>
      </div>
      <.link navigate={~p"/"} class="jam-btn">Back home</.link>
    </div>
    """
  end
end
