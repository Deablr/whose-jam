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

  One thing is kept here and never sent to the server: while a round is on,
  the phone of the player who picked the song shows the same screen as
  everyone else's (anything else would give its owner away), and the name
  they tap to blend in is only remembered in this LiveView.

  When the game ends (`{:game_ended, reason}`: the host ended it, closed the
  host screen, or it sat idle) the phone says so and offers the way home. A
  finished game keeps its final scores on screen.
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.Game
  alias WhoseJam.Game.Standings
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
      # {round, choice}: the name the round's own picker tapped to blend in
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
        {:noreply, assign(socket, join_error: "That name's a little long — keep it under 24.")}

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
         assign(socket, search_error: "Couldn't lock in that pick — the timer may have ended.")}
    end
  end

  def handle_event("pick_song", _params, socket) do
    {:noreply, assign(socket, search_error: "Couldn't lock in that pick — try it again.")}
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
        {:noreply, assign(socket, vote_error: "Couldn't record that vote.")}
    end
  end

  def handle_event("vote", _params, socket) do
    {:noreply, assign(socket, vote_error: "Couldn't record that vote.")}
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
           |> put_flash(:info, "The room's packed — you're in as audience. You can still vote!")
           |> redirect(to: ~p"/claim/#{token}")}
        else
          {:noreply, redirect(socket, to: ~p"/claim/#{token}")}
        end

      {:error, _reason} ->
        {:noreply, assign(socket, join_error: "Couldn't join this game. It may have ended.")}
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
          search_error: "Song search isn't set up on this server right now."
        )

      {:error, :quota_exceeded} ->
        assign(socket,
          search_query: query,
          search_results: [],
          search_error:
            "The music service's search limit for today is used up, " <>
              "so searching won't work until it resets."
        )

      {:error, _other} ->
        assign(socket,
          search_query: query,
          search_results: [],
          search_error: "Couldn't reach the music service — try that search again."
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

  defp ended_message(:host_ended), do: "That's the night. Thanks for playing."
  defp ended_message(:host_left), do: "The host closed the game screen, so the game has ended."
  defp ended_message(:idle), do: "This game closed after sitting idle."
  defp ended_message(_reason), do: "This game has ended."

  # =========================================================================
  # Render
  # =========================================================================

  # A screen that stays one phone-width column however wide the device is.
  @narrow "lg:mx-auto lg:w-full lg:max-w-md"

  # A small status pill: the vote clock and what stands in for it.
  @pill "flex shrink-0 items-center gap-1.5 rounded-full bg-jam-cream/10 px-3 py-1"

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
          # The host's quick-reveals choice retimes every beat, as on the TV.
          is_map(@view) && @view.config[:quick_reveals?] && "jam-quick"
        ]
      }
    >
      <div :if={@art_url} class="jam-ambient" aria-hidden="true">
        <img src={@art_url} alt="" />
      </div>
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
    <div class="mb-4 flex items-center justify-between gap-3 short:mb-3">
      <img
        src={~p"/images/whose-jam-logo.svg"}
        alt="Whose Jam"
        class="h-14 -ml-2 shrink-0 short:h-10"
      />
      <div class="flex min-w-0 items-center gap-2">
        <span
          :if={@role == :audience}
          class="jam-chip shrink-0 !bg-jam-orange !px-3 !py-1 text-xs !text-jam-ink"
        >
          Audience
        </span>
        <span :if={@my_name} id="me" class="jam-chip jam-chip-on min-w-0 !px-3 !py-1 text-xs">
          <span class="truncate">{@my_name}</span>
          <%!-- At a reveal the score waits for the answer, as the TV's does. --%>
          <span :if={@my_score} id="my-score" class="grid shrink-0 tabular-nums">
            <span
              :if={@my_gain > 0}
              id={"my-old-score-#{@view.round.index}"}
              class="jam-out jam-beat-3 whitespace-nowrap text-right [grid-area:1/1]"
              aria-hidden="true"
            >
              {score_label(@my_score - @my_gain, @role)}
            </span>
            <span
              id={"my-new-score-#{@my_gain > 0 && @view.round.index}"}
              class={[
                "whitespace-nowrap text-right [grid-area:1/1]",
                @my_gain > 0 && "jam-rise jam-beat-3"
              ]}
            >
              {score_label(@my_score, @role)}
            </span>
          </span>
        </span>
        <span class="jam-chip shrink-0 !px-3 !py-1 text-xs tracking-widest">
          {@code}
        </span>
      </div>
    </div>
    """
  end

  defp my_score(%{view: %{phase: phase, scores: scores}, player_id: player_id})
       when phase in [:playing, :finished] and is_binary(player_id),
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
      <.jam_badge icon="hero-question-mark-circle" tone="quiet" class="text-7xl" />
      <div>
        <h1 class="font-display text-2xl">No game here</h1>
        <p class="mt-2 text-jam-cream/60">
          There's no game with the code <span class="font-display tabular-nums text-jam-cream">{@code}</span>. It may have ended.
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
          class="rounded-2xl border-2 border-jam-cream/10 bg-jam-ink/60 px-5 py-4 text-center font-display text-3xl uppercase tracking-[0.3em] text-jam-cream placeholder:normal-case placeholder:tracking-normal placeholder:text-xl placeholder:text-jam-cream/30 focus:border-jam-pink focus:outline-none"
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
    <div class={["flex flex-1 flex-col justify-center", @narrow]}>
      <h1 class="font-display text-4xl leading-tight">Pick a name</h1>
      <p class="mt-2 text-jam-cream/60">
        You're joining room <span class="font-display tracking-widest text-jam-cream">{@code}</span>.
      </p>
      <%!-- Said before the name goes in, not after: who this makes you. --%>
      <p
        :if={@joins_audience?}
        id="audience-join-note"
        class="mt-3 rounded-2xl bg-jam-cream/5 px-4 py-3 text-jam-cream/85"
      >
        This game has started, so you'll join the audience: guess every song, +1 for each one you call.
      </p>

      <form phx-submit="join" class="mt-8 space-y-4">
        <input
          type="text"
          name="name"
          autocomplete="off"
          autofocus
          maxlength="24"
          placeholder="Your name"
          aria-label="Your name"
          class="w-full rounded-2xl border-2 border-jam-cream/10 bg-jam-ink/60 px-5 py-4 text-lg text-jam-cream placeholder-jam-cream/40 focus:border-jam-pink focus:outline-none"
        />
        <p :if={@join_error} class="text-sm text-jam-red">{@join_error}</p>
        <button
          type="submit"
          class="jam-btn w-full text-lg"
        >
          {if @joins_audience?, do: "Join the audience", else: "Join game"}
        </button>
      </form>
      <p :if={!@joins_audience?} class="mt-6 text-center text-sm text-jam-cream/50">
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
    <div class="flex flex-1 flex-col lg:my-auto lg:grid lg:flex-none lg:grid-cols-2 lg:items-start lg:gap-10">
      <div>
        <div class="jam-panel p-6 text-center">
          <.jam_badge icon="hero-check" tone="mint" class="jam-pop mx-auto text-6xl" />
          <%!-- A name is never broken across lines: a long one gets a line of
               its own, a size down. --%>
          <h1 class={[
            "mt-4 font-display leading-tight",
            if(String.length(@my_name || "") > 14, do: "text-xl", else: "text-2xl")
          ]}>
            You're in, <span class="whitespace-nowrap">{@my_name}</span>
          </h1>
          <p :if={@promoted?} id="promoted" class="mt-1 font-bold text-jam-mint">
            A seat opened up. You're playing this time.
          </p>
          <p class="mt-1 text-jam-cream/60">
            <%= if @role == :player do %>
              {lobby_wait(@view)}
            <% else %>
              You're in the audience: you'll vote on every song.
            <% end %>
          </p>
          <p class="jam-eyebrow mt-4">Tonight's theme</p>
          <p id="lobby-vibe" class="font-display text-xl">{@view.theme.name}</p>
        </div>

        <%!-- The one rule that changes how you pick: fooling people scores. --%>
        <%!-- Left-aligned, the +1s in a column, as the TV sets them. --%>
        <ul id="how-to-score" class="mx-auto mt-5 w-fit space-y-1 font-bold">
          <li class="flex gap-2">
            <span class="w-7 shrink-0 font-display text-jam-mint">+1</span>
            <span>for each correct guess.</span>
          </li>
          <li :if={@role == :player} class="flex gap-2">
            <span class="w-7 shrink-0 font-display text-jam-orange">+1</span>
            <span>for each player your song fools.</span>
          </li>
          <li :if={@role == :player} class="flex gap-2">
            <span class="w-7 shrink-0 font-display text-jam-orange">+1</span>
            <span>if you call who takes the blame for your song.</span>
          </li>
        </ul>
      </div>

      <div class="mt-6 lg:mt-0">
        <h2 class="jam-eyebrow mb-2">
          Players · {length(@view.players)}
        </h2>
        <div class="flex flex-wrap gap-2">
          <span
            :for={p <- @view.players}
            id={"player-#{p.id}"}
            class={[
              "jam-chip jam-pop text-base",
              p.id == @player_id && "jam-chip-on"
            ]}
          >
            {p.name}
          </span>
        </div>

        <div :if={@view.audience != []} class="mt-5">
          <h2 class="jam-eyebrow mb-2">
            Audience · {length(@view.audience)}
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
    <div class="flex flex-1 flex-col items-center justify-center gap-5 text-center">
      <.jam_badge icon="hero-musical-note" class="text-7xl" />
      <h1 class="font-display text-2xl">
        {if @ready?, do: "Everyone's ready", else: "You're in the audience"}
      </h1>
      <div :if={!@ready?} class="space-y-1">
        <p class="font-bold text-jam-cream">Guess who picked each song. +1 for each you call.</p>
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
          class="mt-1 font-display text-3xl tabular-nums"
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
      <.jam_badge icon="hero-check" tone="mint" class="text-7xl" />
      <h1 class="font-display text-xl">Nothing to pick this time</h1>
      <p class="text-jam-cream/60">Hang tight for the music.</p>
    </div>

    <div
      :if={@total > 0}
      class="flex flex-1 flex-col lg:mt-[6vh] lg:grid lg:flex-none lg:grid-cols-2 lg:items-start lg:gap-10"
    >
      <div>
        <div class="mb-4 flex items-center justify-between gap-3">
          <div class="text-sm font-bold text-jam-cream/80">
            <%= if @total > 1 do %>
              Prompt {@index + 1} of {@total} · {@answered} picked
            <% else %>
              {if @total == 1 and @answered == 1 and is_nil(@edit_qid),
                do: "Your pick",
                else: "Pick a song for this prompt"}
            <% end %>
          </div>
          <div
            :if={!all_picked?(@view)}
            class="flex items-center gap-1.5 rounded-full bg-jam-cream/10 px-3 py-1"
          >
            <.icon name="hero-clock" class="size-4 text-jam-pink" />
            <span
              id="countdown-answer"
              phx-hook="Countdown"
              data-deadline={@view.answering.deadline_ms}
              class="font-display text-sm tabular-nums"
            >
              --
            </span>
          </div>
        </div>

        <%!-- Once there are songs to choose from, the prompt steps back (a
             smaller line, still all there) so more of them fit. --%>
        <div class={["jam-panel", if(@search_results != [], do: "px-4 py-3", else: "p-6")]}>
          <div class="text-xs font-semibold uppercase tracking-wide text-jam-pink">
            Your prompt
          </div>
          <h1 class={[
            "mt-1 font-display leading-snug",
            if(@search_results != [], do: "text-lg", else: "text-2xl")
          ]}>
            {@question.prompt}
          </h1>
        </div>
      </div>

      <div>
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

  defp search_placeholder(%{music: %{name: name}}), do: "Search #{name} for a song…"
  defp search_placeholder(_view), do: "Search for a song…"

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
        class="jam-rise rounded-3xl border border-jam-mint/50 bg-jam-mint/10 p-4"
      >
        <div class="mb-2 flex items-center gap-2 text-sm font-semibold text-jam-mint">
          <.icon name="hero-check-circle" class="size-5" /> Locked in
        </div>
        <div class="flex items-center gap-3">
          <img
            :if={@question.song.album_art_url}
            src={@question.song.album_art_url}
            alt=""
            class="size-14 rounded-lg object-cover"
          />
          <div class="min-w-0">
            <div class="truncate font-semibold">{@question.song.name}</div>
            <div class="truncate text-sm text-jam-cream/60">{@question.song.artist}</div>
          </div>
        </div>
        <button
          phx-click="change_pick"
          phx-value-question={@question.question_id}
          class="jam-btn jam-btn-ghost mt-4 w-full border border-jam-cream/30 text-sm"
        >
          Change pick
        </button>
      </div>

      <p
        :if={not @editing? and @answered == @total}
        id="waiting-on"
        class="mt-4 text-center text-sm text-jam-cream/60"
      >
        {waiting_on(@view, @player_id)}
      </p>
      {own_song_explainer(assigns)}

      <div :if={@editing?}>
        <%!-- While another song is looked for, the saved one stays in view:
             it still counts until a new one is picked. --%>
        <div
          :if={@question.submitted?}
          id="current-pick"
          class="mb-3 flex items-center gap-3 rounded-2xl border border-jam-mint/40 bg-jam-mint/10 p-3"
        >
          <img
            :if={@question.song.album_art_url}
            src={@question.song.album_art_url}
            alt=""
            class="size-12 shrink-0 rounded-lg object-cover"
          />
          <div class="min-w-0 flex-1">
            <div class="text-xs font-bold uppercase tracking-wide text-jam-mint">
              Current pick · saved
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
            class="pointer-events-none absolute left-4 top-[1.15rem] size-6 text-jam-cream/50"
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
            class="peer w-full rounded-2xl border-2 border-jam-cream/25 bg-jam-ink/60 py-4 pl-12 pr-5 text-jam-cream placeholder-jam-cream/50 focus:border-jam-pink focus:outline-none"
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
          <p
            :if={@search_results == [] and @search_query == "" and is_nil(@search_error)}
            id="search-hint"
            class="mt-3 text-center text-sm text-jam-cream/50 peer-[:not(:placeholder-shown)]:hidden"
          >
            Type a song or an artist. Results show up as you type.
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
            class="flex w-full items-center gap-3 rounded-2xl bg-jam-cream/5 p-3 text-left transition-colors hover:bg-jam-cream/10 active:bg-jam-cream/15"
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
              <.icon name="hero-musical-note" class="size-6 text-jam-cream/50" />
            </div>
            <div class="min-w-0 flex-1">
              <div class="line-clamp-2 font-semibold leading-snug">{track.name}</div>
              <div class="truncate text-sm text-jam-cream/60">{track.artist}</div>
            </div>
            <%!-- The whole row is the button; this only says so, quietly, so
                 a list of results isn't a column of pink buttons. --%>
            <span class="shrink-0 rounded-lg border-2 border-jam-pink/70 px-4 py-2 font-display text-base text-jam-pink">
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
    <div
      :if={not @editing? and @answered == @total}
      id="own-song-explainer"
      class="mt-3 rounded-2xl bg-jam-cream/5 px-4 py-3 text-base leading-snug text-jam-cream/85"
    >
      <span class="font-bold text-jam-cream">Your own song comes up too.</span>
      Then call who'll take the blame for it: +1 if you're right.
    </div>
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
      0 -> "All done. Here comes the music."
      1 -> "You're done. Waiting on 1 more."
      n -> "You're done. Waiting on #{n} more."
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
      <div class="jam-round-card-text max-w-xl space-y-3 text-center">
        <p class="font-display text-4xl">
          Round {@round.index + 1} <span class="text-jam-cream/40">of {@round.total}</span>
        </p>
        <%!-- The same words as the TV's card: a prompt's second song is
             framed as that. --%>
        <p :if={@round.prompt && second_take?(@round)} class="jam-eyebrow">
          Another pick for
        </p>
        <p
          :if={@round.prompt}
          class="font-display text-xl leading-snug text-balance text-jam-cream/90"
        >
          {@round.prompt}
        </p>
      </div>
    </div>
    <div class="flex flex-1 flex-col lg:mt-[6vh] lg:grid lg:flex-none lg:grid-cols-2 lg:items-start lg:gap-10">
      <div>
        <div
          :if={@show_times_up}
          class="mb-4 flex items-start gap-2 rounded-2xl bg-jam-orange/15 px-4 py-3 text-sm text-jam-orange"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
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
        <p :if={@round_state == :revealing} id="song-line" class="text-sm text-jam-cream/60">
          Round {@round.index + 1} of {@round.total}
        </p>
        <div :if={@round_state != :revealing}>{now_playing(assigns)}</div>

        <%!-- Guess-who rounds say what the song was picked for. --%>
        <figure
          :if={@round.prompt}
          id="round-prompt"
          class="mt-4 rounded-2xl border-l-4 border-jam-pink bg-jam-cream/5 px-4 py-3 short:mt-2"
        >
          <figcaption class="text-xs font-semibold uppercase tracking-wide text-jam-pink">
            The prompt <%!-- The round's one clue, as the TV gives it. --%>
            <span :if={take_label(@round)} id="prompt-take" class="text-jam-cream/70">
              · {take_label(@round)}
            </span>
          </figcaption>
          <blockquote class="mt-1 font-display text-lg leading-snug">
            {@round.prompt}
          </blockquote>
        </figure>
      </div>

      <div class="flex flex-1 flex-col lg:flex-none">
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

  # The round just before had this same prompt.

  # How many songs were picked for this round's prompt, and which this is.
  defp take_label(%{prompt_take: %{nth: 1, of: of}}), do: "#{of} people picked for it"
  defp take_label(%{prompt_take: %{nth: 2, of: 2}}), do: "the other pick"
  defp take_label(%{prompt_take: %{nth: nth, of: of}}), do: "pick #{nth} of #{of}"
  defp take_label(_round), do: nil

  # Not the first song picked for its prompt.
  defp second_take?(%{prompt_take: %{nth: nth}}), do: nth > 1
  defp second_take?(_round), do: false

  defp now_playing(assigns) do
    ~H"""
    <div id="now-playing" class="flex items-center gap-3">
      <%!-- Keyed by round, so a new round never shows the last one's cover. --%>
      <img
        :if={@round.song.album_art_url}
        id={"art-#{@round.index}-#{@view.subround_index}"}
        src={@round.song.album_art_url}
        alt=""
        class="size-14 shrink-0 rounded-xl object-cover shadow-lg short:size-11"
      />
      <div
        :if={!@round.song.album_art_url}
        class="flex size-14 shrink-0 items-center justify-center rounded-xl bg-jam-cream/10 short:size-11"
      >
        <.icon name="hero-musical-note" class="size-7 text-jam-cream/50" />
      </div>
      <div class="min-w-0">
        <div class="jam-eyebrow !text-xs">
          Round {@round.index + 1} of {@round.total}
        </div>
        <div class="truncate font-display text-lg leading-tight short:text-base">
          {@round.song.name}
        </div>
        <div class="truncate text-sm text-jam-cream/60 short:text-xs">{@round.song.artist}</div>
      </div>
    </div>
    """
  end

  defp revealing_body(assigns) do
    ~H"""
    <div
      id="phone-listening"
      class="jam-rise flex flex-1 flex-col items-center justify-center gap-5 py-6 text-center short:gap-3 short:py-2"
    >
      <%!-- The song the TV is playing, as the TV has it: a poster, its cover
           printed on a sheet of paper with its name under it, large enough
           to see at arm's length (`.jam-poster` in app.css). --%>
      <figure class="jam-hand jam-poster w-[12.5rem] bg-jam-cream p-3 text-left text-jam-ink short:w-[11.25rem] short:p-2.5">
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
          <.icon name="hero-musical-note" class="size-12 text-jam-ink/40" />
        </div>
        <figcaption class="mt-2 px-0.5">
          <p class="line-clamp-2 break-words break-keep font-display text-xl leading-tight">
            {@round.song.name}
          </p>
          <p class="mt-0.5 line-clamp-2 text-base font-bold leading-snug text-jam-ink/70">
            {@round.song.artist}
          </p>
        </figcaption>
      </figure>
      <div>
        <h1 class="font-display text-2xl">Listen up</h1>
        <p id="listen-note" class="mt-1 text-jam-cream/80">
          {if own_round?(assigns),
            do: "Your song. Keep a straight face.",
            else: "It's playing on the TV."}
        </p>
      </div>
      <%!-- The TV's bar, filling as voting gets nearer. --%>
      <div class="w-full max-w-xs space-y-2">
        <div
          id={"phone-listen-progress-#{@view.subround_index}-#{@round.index}"}
          phx-hook="Progress"
          phx-update="ignore"
          data-deadline={@round.votes_open_ms}
          data-duration={@view.config.vote_delay_s * 1000}
          class="h-2 overflow-hidden rounded-full bg-jam-cream/15"
          aria-hidden="true"
        >
          <span class="block h-full origin-left rounded-full bg-gradient-to-r from-jam-pink to-jam-orange [transform:scaleX(0)]"></span>
        </div>
        <p class="text-sm text-jam-cream/80">
          {if own_round?(assigns), do: "Your prediction opens in", else: "Voting opens in"}
          <span
            id="countdown-votes-open"
            phx-hook="Countdown"
            data-deadline={@round.votes_open_ms}
            class="font-display tabular-nums text-jam-cream"
          ></span>
        </p>
      </div>
    </div>
    """
  end

  # Every phone has the same layout while a round is on, the picker's
  # included: the same heading place, names, button and locked-in screen, so
  # a glance at someone's phone shows its shape, not whose song it is. The
  # picker's job is different (their blame guess: whom the room will wrongly
  # name, for a point), so the words in those places ask them that, and only
  # them. Everyone is also told how this works once, before the first song
  # (see own_song_explainer/1).
  defp voting_body(assigns) do
    picked = assigns.me.vote
    assigns = assign(assigns, picked: picked, own?: own_round?(assigns))

    if not is_nil(picked) and not assigns.view.config.allow_vote_change? do
      assigns =
        assign(assigns, picked_label: choice_label(assigns.round, picked), bar_class: @bar)

      ~H"""
      <%!-- A lock, not a tick: the vote is in, not yet right. The same on
           every phone, the picker's included. --%>
      <.locked_card
        id="phone-voted"
        label="Locked in"
        label_id="locked-note"
        name={@picked_label || "Vote locked in"}
        note={"Eyes on the TV · " <> votes_in(@round)}
        note_class="text-xl font-bold text-jam-cream"
        badge_class="jam-pop"
        class="flex-1 pt-4"
      >
        {vote_timer(Map.put(assigns, :timer_bar?, true))}
        <span :if={is_nil(@round.deadline_ms)} class={@bar_class}>
          <.icon name="hero-clock" class="size-5 text-jam-pink" />
          <span class="font-bold text-jam-cream/80">Waiting for the others</span>
        </span>
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
      <div id="phone-voting" class="mt-5 flex flex-1 flex-col lg:mt-0">
        <%!-- In the last five seconds the question turns amber with the clock.
             On a phone the clock has its own row under the question, kept
             whether or not a clock runs yet, so the question never wraps
             beside it and nothing below moves when it starts. --%>
        <div class="mb-3 flex flex-col gap-2 transition-colors has-[[data-urgent]]:text-jam-orange sm:flex-row sm:items-center sm:justify-between sm:gap-3">
          <h1 class="font-display text-xl">
            {if @change? and all_in?(@round),
              do: "Final changes",
              else: vote_question(@round)}
          </h1>
          <div class="flex min-h-7 items-center">{vote_timer(assigns)}</div>
        </div>

        <%!-- What to do stays on screen for the picker after a tap, so the
             task never turns back into an ordinary vote. --%>
        <%!-- The hint and the line that says a choice is saved each keep
             their place from the first tap to the last, so the names below
             never move under a thumb about to tap again. --%>
        <div class="mb-3 space-y-1">
          <p id="vote-hint" class="text-base text-jam-cream/75">
            {vote_hint(@round, @own?, @change?)}
          </p>
          <p :if={@change?} class={["text-sm text-jam-mint", !@picked && "invisible"]}>
            {cond do
              all_in?(@round) -> "Everyone's in. Last chance to switch."
              @own? -> "Prediction saved."
              true -> "Vote's in."
            end}
          </p>
          <p :if={@vote_error} class="text-sm text-jam-red">{@vote_error}</p>
        </div>

        <%!-- Names are short, so they sit two to a row and all fit on a
             small phone; prompts need the full width. They follow the
             question; the button that commits is under the thumb. --%>
        <div class={
          [
            "grid gap-2.5",
            # Every tile the same size, however long the name on it: a name
            # too long for half the width puts every choice on a row of its
            # own, and a name never wraps (a long one is set a size down).
            @round.style == :guess_who && "auto-rows-fr",
            @cols == 2 && "grid-cols-2",
            @cols == 3 && "grid-cols-3"
          ]
        }>
          <button
            :for={choice <- @choices}
            phx-click={if @change?, do: "vote", else: "choose"}
            phx-value-choice={choice.id}
            aria-pressed={to_string(@chosen == choice.id)}
            class={
              [
                "relative min-h-14 min-w-0 rounded-2xl border px-4 py-3 active:border-jam-pink active:ring-4 active:ring-jam-pink short:min-h-12 short:py-2 lg:[@media(max-height:800px)]:min-h-12 lg:[@media(max-height:800px)]:py-2",
                # Names are the game's cast, so they wear the display face.
                @round.style == :guess_who &&
                  "flex items-center justify-center gap-2 font-display",
                @round.style == :guess_who && if(@cols == 3, do: "px-3", else: "px-9"),
                @round.style == :guess_who &&
                  if(@cols == 3, do: "text-lg", else: name_size(@choices)),
                # Two to a row, an odd one out sits centred on the last row,
                # the same size as the rest. (Only then: spanning two columns
                # of a one-column grid would make a second one, sized to its
                # names, and the tiles uneven.) Three to a row, a lone last
                # one sits in the middle.
                @cols == 2 &&
                  "last:odd:col-span-2 last:odd:mx-auto last:odd:w-[calc(50%_-_0.3125rem)]",
                @cols == 3 && rem(length(@choices), 3) == 1 && "last:col-start-2",
                # A long name takes the whole row rather than breaking.
                @round.style != :guess_who && "pr-11 text-left text-lg font-bold",
                # Chosen is not yet locked in, so it doesn't look finished: the
                # tile keeps its colour (and stays as readable as the rest)
                # and takes a ring and a mark. Solid pink is for the button
                # that commits it.
                @chosen == choice.id &&
                  "border-jam-pink bg-jam-cream text-jam-ink ring-4 ring-jam-pink",
                @chosen != choice.id &&
                  "border-jam-cream bg-jam-cream text-jam-ink hover:bg-white"
              ]
            }
          >
            <span class={@round.style == :guess_who && "min-w-0 truncate text-center leading-tight"}>
              {if @round.style == :guess_who, do: choice.name, else: choice.prompt}
            </span>
            <%!-- The chosen one says so with more than its colour; the tick
                 sits out of the flow, so nothing moves when it appears. --%>
            <.icon
              :if={@chosen == choice.id}
              name="hero-check-circle-solid"
              class={[
                "absolute text-jam-pink",
                if(@cols == 3,
                  do: "right-1 top-1 size-5",
                  else: "right-3 top-1/2 size-6 -translate-y-1/2"
                )
              ]}
            />
          </button>
        </div>

        <%!-- The commit, where the thumb already is. Always there, so the
             names above never move when one is tapped, and stuck to the
             bottom of the screen, so it is never below the fold. --%>
        <button
          :if={!@change?}
          id="lock-vote"
          type="button"
          phx-click="lock"
          disabled={is_nil(@chosen)}
          class="jam-btn sticky bottom-6 z-10 mt-4 w-full text-lg disabled:!opacity-100 disabled:!bg-transparent disabled:!text-jam-cream/55 disabled:!shadow-none disabled:ring-2 disabled:ring-inset disabled:ring-jam-cream/20"
        >
          {if @chosen_label, do: "Lock in #{@chosen_label}", else: "Lock in"}
        </button>
      </div>
      """
    end
  end

  attr :id, :string, required: true
  attr :icon, :string, default: "hero-lock-closed"
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :note, :string, default: nil
  attr :note_class, :any, default: nil
  attr :label_id, :string, default: nil
  attr :tag, :string, default: "h1"
  attr :badge_class, :any, default: nil
  attr :badge_tone, :string, default: "brand"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  # One screen from the moment a vote is locked in until the answer: what was
  # picked stays where it is, and only the pill under it changes (the clock,
  # then "Eyes on the TV" while the TV has the reveal).
  defp locked_card(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-col items-center text-center", @class]} {@rest}>
      <div class="my-auto flex flex-col items-center gap-4 py-4">
        <.jam_badge icon={@icon} tone={@badge_tone} class={["text-5xl", @badge_class]} />
        <div class="space-y-1">
          <p id={@label_id} class="jam-eyebrow">{@label}</p>
          <.dynamic_tag
            tag_name={@tag}
            class={[
              "line-clamp-2 break-words px-2 font-display leading-tight",
              locked_name_size(@name)
            ]}
          >
            {@name}
          </.dynamic_tag>
        </div>
        <%!-- Where to look next, right under what was picked. --%>
        <p :if={@note} class={@note_class || "text-jam-cream/85"}>{@note}</p>
      </div>
      <%!-- What happens next, as a bar across the foot of the screen, where
           the eye and the thumb rest. --%>
      <div class="w-full">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # How many of the round's voters are in, as the TV counts them.
  defp votes_in(%{votes_received: received, eligible_voters: expected})
       when is_integer(received) and is_integer(expected),
       do: "#{received} of #{max(expected, received)} in"

  defp votes_in(_round), do: "votes coming in"

  # The answer as large as it can be on one line of a phone.
  defp reveal_name_size(name) do
    case String.length(name) do
      n when n <= 8 -> "text-6xl"
      n when n <= 12 -> "text-5xl"
      _ -> "text-4xl"
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

  # The picker's job, in the small line under the question everyone shares
  # (a bold headline of their own could be read from the next seat), in the
  # measure the reveal reports: where most of the wrong guesses land.
  defp vote_hint(%{style: :guess_who}, true, _change?),
    do: "Your song: call who'll take the blame. +1 if most of the wrong guesses land on them."

  defp vote_hint(_round, true, _change?),
    do: "Your song: call which wrong prompt takes the blame. +1 if most wrong guesses land on it."

  defp vote_hint(round, false, true),
    do: "Tap a #{choice_noun(round)} to vote; tap another to switch."

  defp vote_hint(round, false, false), do: "Choose a #{choice_noun(round)}, then lock it in."

  # What the round asks, the same on every phone, the picker's included:
  # their job is in the small line under it (see vote_hint/3).
  defp vote_question(%{style: :guess_who}), do: "Whose jam is this?"
  defp vote_question(_round), do: "Which prompt was this for?"

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
  defp grid_cols(%{style: :guess_who}, choices) do
    cond do
      long_names?(choices) -> 1
      length(choices) >= 7 and Enum.all?(choices, &(String.length(&1[:name] || "") <= 6)) -> 3
      true -> 2
    end
  end

  defp grid_cols(_round, _choices), do: 1

  # One size for every name on the grid, set by the longest: names run up to
  # 24 characters and each must fit its tile on one line.
  defp name_size(choices) do
    case choices |> Enum.map(&String.length(&1[:name] || "")) |> Enum.max(fn -> 0 end) do
      n when n <= 16 -> "text-xl"
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

  defp vote_timer(assigns) do
    assigns =
      assign(
        assigns,
        :timer_label,
        if(all_in?(assigns.round), do: "Reveal in", else: "Time left")
      )

    assigns = assign(assigns, pill_class: @pill, bar?: assigns[:timer_bar?] == true)

    ~H"""
    <%!-- In the header, a pill of one fixed width (so a ticking clock never
         reflows the question beside it); at the foot of a locked-in screen,
         plain words, not a slab that looks like a button. --%>
    <div class={
      if(@bar?,
        do:
          "flex items-center justify-center gap-1.5 py-3 transition-colors has-[[data-urgent]]:[&_*]:!text-jam-orange",
        else: [
          @pill_class,
          "w-[10rem] justify-center whitespace-nowrap transition-colors has-[[data-urgent]]:bg-jam-orange has-[[data-urgent]]:text-jam-ink has-[[data-urgent]]:[&_*]:text-jam-ink"
        ]
      )
    }>
      <.icon name="hero-clock" class="size-4 text-jam-pink" />
      <span class="text-sm font-bold text-jam-cream/80">{@timer_label}</span>
      <span
        id="countdown-vote"
        phx-hook="Countdown"
        data-deadline={@round.deadline_ms}
        class="font-display text-sm tabular-nums"
      >
        --
      </span>
    </div>
    """
  end

  # Every vote the round is waiting for is in: the reveal is seconds away.
  defp all_in?(round),
    do: round.eligible_voters > 0 and round.votes_received >= round.eligible_voters

  # The reveal belongs to the room, so the phone sends eyes to the TV while the
  # reveal plays out there (`.jam-beat-1` and `-2` in app.css) and only then
  # shows the answer with what it meant for this player and where they stand.
  defp results_body(assigns) do
    assigns =
      assigns
      |> assign(:own?, own_round?(assigns))
      |> assign(:submitter_name, participant_name(assigns.view, assigns.round.submitter_id))
      |> assign(:outcome, outcome(assigns))
      |> assign(:standing, round_standing(assigns))
      |> assign(:guessed, guessed(assigns))
      |> assign(:bar_class, @bar)

    ~H"""
    <div
      id="phone-results"
      class="relative flex flex-1 flex-col items-center justify-center gap-5 py-10 text-center"
    >
      <%!-- While the TV has the reveal, the phone holds what its owner said,
           so it is never an empty screen. The picker's shows their guess: it
           is still the same screen as everyone's. --%>
      <%!-- The locked-in screen it follows, unchanged but for its pill. --%>
      <.locked_card
        id={"eyes-up-#{@round.index}"}
        icon={if @guessed, do: "hero-lock-closed", else: "hero-clock"}
        badge_tone={if @guessed, do: "brand", else: "quiet"}
        label={if @guessed, do: "Locked in", else: "Time's up"}
        name={@guessed || "No vote"}
        note={
          if @guessed,
            do: "Eyes on the TV",
            else: "Time ran out before you #{if @own?, do: "guessed", else: "voted"}."
        }
        note_class={@guessed && "text-xl font-bold text-jam-cream"}
        tag="p"
        class="jam-out jam-beat-3 absolute inset-0"
        aria-hidden="true"
      />

      <div :if={@round.style == :guess_who} class="jam-rise jam-beat-3 jam-after">
        <div class="font-display text-lg text-jam-cream/70">It was…</div>
        <div class={[
          "mt-1 break-words px-2 font-display leading-tight text-jam-pink",
          reveal_name_size(if(@own?, do: "You", else: @submitter_name || ""))
        ]}>
          {if @own?, do: "You", else: @submitter_name}
        </div>
      </div>
      <div :if={@round.style != :guess_who} class="jam-rise jam-beat-3 jam-after">
        <div class="jam-eyebrow">The prompt was</div>
        <div class="mt-1 font-display text-2xl leading-snug text-jam-pink">
          {@round.correct_prompt}
        </div>
        <div :if={@submitter_name} class="mt-2 text-sm text-jam-cream/60">
          picked by {if @own?, do: "you", else: @submitter_name}
        </div>
      </div>

      <div
        id="my-outcome"
        class={
          [
            "jam-rise jam-beat-3 jam-after jam-hand w-full px-6 py-5",
            # The colours the lobby taught: mint for a right guess, orange for
            # a bluff that worked.
            cond do
              @outcome[:bluff?] && @outcome.win? -> "bg-jam-orange text-jam-ink"
              @outcome.win? -> "bg-jam-mint text-jam-night"
              # A miss is a moment too: a solid colour, as bright as the
              # others, not a dimmed slab.
              true -> "bg-[#c43c63] text-jam-cream"
            end
          ]
        }
      >
        <p class="font-display text-xl leading-snug text-balance">{@outcome.headline}</p>
        <p class="mt-1 text-base font-bold text-balance">
          {@outcome.detail}
        </p>
        <p
          :if={@outcome[:blame]}
          id="my-blame"
          class="mt-1 text-base font-bold text-balance"
        >
          {@outcome[:blame]}
        </p>
      </div>

      <p
        :if={@standing}
        id="my-standing"
        class="jam-rise jam-beat-3 jam-after rounded-full bg-jam-cream/10 px-4 py-1.5 text-sm font-bold text-jam-cream"
      >
        {@standing}
      </p>
    </div>
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
      is_nil(assigns.me.vote) -> miss("You didn't vote")
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

    # In seat order, as the TV names them.
    fooled = for p <- view.players ++ view.audience, p.id in wrong, do: p.name

    case {votes, fooled} do
      {[], _} -> miss("Nobody voted")
      # A prediction still gets its line: it had nobody to come true on.
      {_, []} -> Map.put(miss("Nobody fell for it"), :blame, blame_line(round))
      {_, names} -> bluff("You fooled #{join_names(names)}", round, delta)
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
      detail: "+#{fooling} for fooling them",
      blame: blame
    }
  end

  # The TV's sentence: whom the fooled blamed and whether this player called
  # it, led by its point when it scored one (a miss has none).
  defp blame_line(%{forecast: %{choice: choice, right?: right?}} = round) do
    case blamed(round) do
      nil -> "Guessed #{guess_name(round, choice)} · nobody was fooled"
      took when right? -> "+1 " <> prediction(choice, took, true, round)
      took -> prediction(choice, took, false, round)
    end
  end

  defp blame_line(_round), do: nil

  # The TV's words: who took the blame (most of the wrong guesses).
  defp prediction(_choice, took, true, _round),
    do: "Called the blame: #{join_names(took)}"

  defp prediction(choice, took, false, round),
    do: "Guessed #{guess_name(round, choice)} · #{join_names(took)} took the blame"

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

    case win("You called it", delta) do
      %{win?: true} = won -> %{won | detail: won.detail <> " · " <> company}
      missed -> missed
    end
  end

  defp win(headline, delta) when delta > 0,
    do: %{win?: true, headline: headline, detail: "+" <> points(delta)}

  defp win(headline, _delta), do: miss(headline)

  defp miss(headline), do: %{win?: false, headline: headline, detail: "No points this round"}

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
        "You're " <> place_line(row, board) <> among
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
      |> assign(:my_cover, my_cover(assigns.view, assigns.player_id))

    ~H"""
    <div class="relative flex flex-1 flex-col lg:mx-auto lg:w-full lg:max-w-5xl lg:justify-center">
      <%!-- Only while the game is live: once the host has ended it, the
           scores a player is looking at must never go away again. The wait is
           as long as the TV holds back the winner (`.jam-until-winner`). --%>
      <p
        :if={@status == :joined}
        id="final-eyes-up"
        class="jam-out jam-until-winner pointer-events-none fixed inset-0 flex flex-col items-center justify-center gap-4 text-center"
        aria-hidden="true"
      >
        <.jam_badge icon="hero-trophy" tone="quiet" class="text-6xl" />
        <span class="font-display text-3xl">Eyes on the TV</span>
        <span class="text-base text-jam-cream/70">Here comes the winner.</span>
      </p>
      <div
        id="final-result"
        class={[
          "flex flex-1 flex-col lg:grid lg:flex-none lg:grid-cols-[minmax(0,1fr)_minmax(0,26rem)] lg:items-start lg:gap-x-10 [&>*]:lg:col-start-1",
          @status == :joined && "jam-rise jam-after-winner"
        ]}
      >
        <div class={[
          "flex items-center gap-4 rounded-3xl p-4",
          if(@won?, do: "bg-jam-orange text-jam-ink", else: "jam-panel")
        ]}>
          <%!-- The trophy is the winner's; everyone else's card carries their
               own song's cover. --%>
          <.jam_badge
            :if={@won? or is_nil(@my_cover)}
            icon={if @won?, do: "hero-trophy", else: "hero-musical-note"}
            class={["text-5xl", @won? && "!bg-none !bg-jam-ink !text-jam-orange"]}
          />
          <img
            :if={!@won? and @my_cover}
            src={@my_cover}
            alt=""
            class="size-[3rem] shrink-0 rounded-lg object-cover shadow-lg"
          />
          <div class="min-w-0">
            <p class={["jam-eyebrow", @won? && "!text-jam-ink/70"]}>
              {if @won?, do: "That's a wrap", else: winner_line(@players_board)}
            </p>
            <h1
              id="my-place"
              class={[
                "font-display leading-tight text-balance",
                if(@won?, do: "text-4xl", else: "text-2xl")
              ]}
            >
              {if @mine, do: finish_line(@mine, @role, length(@board)), else: "Game over"}
            </h1>
            <p
              :if={recap_line(@me, @role, @mine)}
              id="my-recap"
              class="mt-1 text-sm font-bold opacity-80"
            >
              {recap_line(@me, @role, @mine)}
            </p>
            <%!-- An award the TV gave this player is theirs to keep here. --%>
            <p
              :for={award <- my_awards(@view, @player_id)}
              class={[
                "mt-1 text-sm font-bold",
                if(@won?, do: "text-jam-ink", else: "text-jam-orange")
              ]}
            >
              {award}
            </p>
          </div>
        </div>

        <%= if @status == :ended do %>
          <%!-- One compact row, so the player's own place in the scores below
               stays on screen however short the screen is. --%>
          <div id="game-ended" class="mt-3 flex flex-col items-center gap-2 text-center">
            <p class="text-sm text-jam-cream/75">{ended_message(@end_reason)}</p>
            <.link navigate={~p"/"} class="jam-btn jam-btn-ghost !px-4 !py-2 text-sm">
              Back home
            </.link>
          </div>
        <% else %>
          <p id="what-next" class="mt-3 text-center text-sm text-jam-cream/75">
            Waiting for the host to start another game.
          </p>
        <% end %>

        <%!-- The night's songs are further down than a glance goes. --%>
        <a
          :if={@playlist != []}
          id="to-playlist"
          href="#my-playlist"
          class="mt-3 flex items-center justify-center gap-2 text-sm font-bold text-jam-mint lg:hidden"
        >
          Tonight's playlist · {songs(length(@playlist))}
          <.icon name="hero-arrow-down-mini" class="size-4" />
        </a>

        <%!-- The game's scores, for everyone; the audience's own after them.
             On a wide screen they have a column of their own, so every row
             (this player's included) is in view without scrolling. --%>
        <div id="final-lists" class="lg:!col-start-2 lg:row-span-6 lg:row-start-1">
          <%= for {title, rows, list_id} <- score_lists(@role, @players_board, @board) do %>
            <h2 class="jam-eyebrow mb-2 mt-4">{title}</h2>
            <%!-- The audience's table in the TV's words ("4 correct"), with no
               place when there is only one of them. --%>
            <ol id={list_id}>
              <li
                :for={row <- rows}
                class={
                  [
                    "mb-1.5 flex break-inside-avoid items-center justify-between rounded-xl px-4 py-1 leading-tight",
                    # The colours every board uses: orange for first place, a
                    # pink outline for you.
                    if(list_id == "final-scores" and row.rank == 1,
                      do: "bg-jam-orange text-jam-ink",
                      else: "bg-jam-cream/5"
                    ),
                    row.id == @player_id && "ring-2 ring-inset ring-jam-pink"
                  ]
                }
              >
                <div class="flex min-w-0 items-center gap-3">
                  <span
                    :if={list_id == "final-scores" or length(rows) > 1}
                    class={[
                      "w-9 shrink-0 text-sm font-bold tabular-nums",
                      cond do
                        list_id == "final-scores" and row.rank == 1 -> "text-jam-ink/70"
                        row.rank == 1 -> "text-jam-orange"
                        true -> "text-jam-cream/70"
                      end
                    ]}
                  >
                    {Standings.ordinal(row.rank)}
                  </span>
                  <span class="truncate font-semibold">{row.name}</span>
                </div>
                <span :if={list_id == "final-scores"} class="font-display text-lg tabular-nums">
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
          <h2 class="jam-eyebrow mb-2 mt-5">Tonight's playlist</h2>
          <ol class="space-y-1.5">
            <li
              :for={song <- @playlist}
              class="flex items-center justify-between gap-4 rounded-xl bg-jam-cream/5 px-4 py-2 leading-tight"
            >
              <span class="min-w-0">
                <span class="block truncate font-semibold">{song.song_name}</span>
                <span :if={song.artist} class="block truncate text-sm text-jam-cream/65">
                  {song.artist}
                </span>
              </span>
              <span class="shrink-0 text-sm text-jam-cream/65">{song.picked_by}</span>
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
        picked_by: participant_name(view, song.player_id) || "someone"
      }
    end
  end

  defp playlist(_view), do: []

  # This player's first song with a cover, for their final card.
  defp my_cover(%{playlist: songs}, player_id) when is_list(songs) do
    Enum.find_value(songs, fn song ->
      url = Map.get(song, :album_art_url)
      if song.player_id == player_id and is_binary(url) and url != "", do: url
    end)
  end

  defp my_cover(_view, _player_id), do: nil

  # The player's own game in a line: what they called and whom they fooled.
  # How their game went, as a sum that comes to their score: every way their
  # points came, with a way that brought none left out.
  defp recap_line(%{recap: %{} = recap}, :player, %{score: score}) do
    [
      recap.called > 0 && "#{recap.called} right",
      recap.fooled > 0 && "#{recap.fooled} fooled",
      Map.get(recap, :blamed, 0) > 0 && "#{predictions(recap.blamed)}"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      parts -> points(score) <> " · " <> Enum.join(parts, ", ")
    end
  end

  defp recap_line(_me, _role, _mine), do: nil

  defp songs(1), do: "1 song"
  defp songs(n), do: "#{n} songs"

  # Who won, for the cards of everyone who didn't.
  defp winner_line(board) do
    case Enum.filter(board, &(&1.rank == 1)) do
      [] -> "That's a wrap"
      [winner] -> "#{winner.name} won"
      winners when length(winners) == length(board) -> "That's a wrap"
      [a, b] -> "#{a.name} & #{b.name} tied"
      winners -> "#{length(winners)} tied for the win"
    end
  end

  defp predictions(1), do: "1 prediction"
  defp predictions(n), do: "#{n} predictions"

  # Which tables the end screen lists: the game's, and for the audience their
  # own as well.
  defp score_lists(:audience, players_board, board),
    do: [
      {"Final scores", players_board, "final-scores"},
      {"Audience · correct guesses", board, "audience-scores"}
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

  # The awards this player holds, worded as the TV words them. Like the TV, an
  # award more than two players share singles nobody out, so it isn't shown.
  defp my_awards(%{awards: %{} = awards}, player_id) do
    bluff =
      case awards[:best_bluff] do
        %{fooled: fooled, bluffs: bluffs} when length(bluffs) <= 2 and fooled > 1 ->
          for %{player_id: ^player_id, song_name: song} <- bluffs,
              do: "Best bluff: #{song} fooled #{fooled}"

        _ ->
          []
      end

    sharpest =
      case awards[:sharpest] do
        %{called: called, player_ids: ids} when length(ids) <= 2 and called > 1 ->
          if player_id in ids, do: ["Sharpest ears: #{called} right"], else: []

        _ ->
          []
      end

    Enum.take(bluff, 1) ++ sharpest
  end

  defp my_awards(_view, _player_id), do: []

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
      <.jam_badge icon="hero-hand-raised" tone="quiet" class="text-7xl" />
      <div>
        <h1 class="font-display text-2xl">Game over</h1>
        <p class="mt-2 text-jam-cream/60">{ended_message(@end_reason)}</p>
      </div>
      <.link navigate={~p"/"} class="jam-btn">Back home</.link>
    </div>
    """
  end
end
