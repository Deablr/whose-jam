defmodule WhoseJamWeb.HostLive do
  @moduledoc """
  The host screen (`/host/:code`, also served at `/tv/:code`).

  One screen does both jobs: it's the big, dark display the whole room watches
  on the TV, and it carries the host's controls — a slim top bar (music status,
  skip song, settings) plus a settings panel that opens on demand. It renders
  from `WhoseJam.Game.host_state/1` (the shared view plus the music-service
  auth).

  ## Music services

  The UI treats the music service as a pluggable choice: `music_services/2`
  lists every enabled `WhoseJam.Music.Provider`, and everything else speaks in
  terms of "the music service". How a provider is connected depends on its
  `connect_kind/0`: `:oauth_redirect` providers are a plain link to
  `/auth/:provider`; `:none` providers connect on click. When no eligible
  service is connected the lobby prompts the host to connect one.

  A provider may also have a yes/no question about the connected account that
  the server can't answer itself (`WhoseJam.Music.account_question/2` — does
  this account have YouTube Premium?). The lobby asks it as soon as the
  account is connected, and Settings lets the host change the answer. A
  connection that works but is degraded (`WhoseJam.Music.warning/2`) shows a
  warning in the lobby and in Settings; it never blocks the game.

  ## Playback approach

  Playback is **attribute-driven**, not command-driven. The `MusicPlayer` hook
  element carries these data attributes:

    * `data-provider` — which JS player module to run
      (`assets/js/hooks/music/<id>.js`).
    * `data-config` — the provider's `client_config/1` as JSON (for Spotify the
      host's access token, refreshed server-side on a timer via
      `WhoseJam.Music.refresh_if_due/2` + `Game.set_music/3`).
    * `data-uri` — the song URI to be playing *right now*, or `""`.
    * `data-round` — the current round's identity (sub-round + round index).

  `data-uri` holds the current round's song for the whole `:playing` phase
  (listening, voting and the reveal), and `data-round` identifies the round so
  a track repeated in back-to-back rounds still restarts. The hook reconciles
  real playback toward them. When the track finishes the player module reports
  it and the hook pushes `"song_ended"`, which opens voting (or starts the vote
  countdown if voting is already open). Any failure pushes `"playback_error"`
  and we show a visible banner — if the TV never reports the end, the server's
  voting-safety timer starts the countdown, so a dead player never wedges the
  game. Providers with `video?/0` get the player shown on screen, where the
  album art would be, while a song plays.

  ## Ending the game

  Each connected host screen attaches itself to the game
  (`WhoseJam.Game.attach_host/2`), so closing the last one ends the game for
  everyone once a short grace passes. The final scoreboard's Exit game button
  ends it at once (`WhoseJam.Game.end_game/1`). Either way the server
  broadcasts `{:game_ended, reason}`. A host screen on the final scoreboard
  when its host exits stays on a closing card, which links to hosting the
  next game; any other goes back to the start page.
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.Game
  alias WhoseJam.Game.{Config, Standings}
  alias WhoseJam.Music

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      # The game lasts while a host screen is open. With no game under this
      # code there is nothing to attach to, and the screen says so.
      _ = Game.attach_host(code, self())
    end

    join_url = url(~p"/play/#{code}")

    socket =
      socket
      |> assign(
        code: code,
        page_title: "Room " <> code,
        view: Game.host_state(code),
        join_url: join_url,
        qr_svg: qr_svg(join_url),
        settings_open?: false,
        playlist_open?: false,
        finale_seen?: false,
        closing: nil,
        music_prompt_dismissed?: false,
        music_question_dismissed?: false,
        playback_ready?: false,
        playback_error: nil,
        refresh_timer: nil
      )
      |> assign_playback()

    {:ok, socket}
  end

  @impl true
  def handle_info({:game_state, _public}, socket) do
    # The broadcast payload omits the music-service auth; refetch the host view
    # so the connect status always reflects the latest token/premium state.
    previous = music_of(socket.assigns.view)
    socket = assign(socket, view: Game.host_state(socket.assigns.code))

    socket =
      if music_of(socket.assigns.view) != previous, do: assign_playback(socket), else: socket

    {:noreply, socket}
  end

  # The game is over and gone, whichever host screen ended it: back to the
  # start, where the host can set up the next one.
  #
  # A game the host ended from its final scoreboard gets a closing card
  # instead: the last thing the room sees on the TV is the game signing off,
  # and it stays there (never the start page's join form), with the way to
  # host the next one. It is drawn from the last view this screen had
  # (nothing is fetched from a game that is gone).
  def handle_info({:game_ended, :host_ended}, %{assigns: %{view: %{phase: :finished}}} = socket) do
    {:noreply, assign(socket, closing: closing(socket.assigns.view))}
  end

  def handle_info({:game_ended, reason}, socket) do
    {:noreply, socket |> put_flash(:info, ended_message(reason)) |> push_navigate(to: ~p"/")}
  end

  def handle_info(:refresh_token, socket) do
    {:noreply, assign_playback(socket)}
  end

  @impl true
  def handle_event("open_settings", _params, socket) do
    {:noreply, assign(socket, settings_open?: true)}
  end

  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, settings_open?: false)}
  end

  def handle_event("dismiss_music_prompt", _params, socket) do
    {:noreply, assign(socket, music_prompt_dismissed?: true)}
  end

  def handle_event("dismiss_music_question", _params, socket) do
    {:noreply, assign(socket, music_question_dismissed?: true)}
  end

  # The host's answer to the connected provider's account question. It is
  # stored in the auth, so it reaches this screen back through the broadcast.
  def handle_event("answer_music_question", %{"answer" => answer}, socket)
      when answer in ["yes", "no"] do
    with %{music: %{id: provider_id}, music_auth: auth} <- socket.assigns.view,
         {:ok, answered} <- Music.answer_account_question(provider_id, auth, answer == "yes"),
         :ok <- Game.set_music(socket.assigns.code, provider_id, answered) do
      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't save that answer. Please try again.")}
    end
  end

  def handle_event("answer_music_question", _params, socket) do
    {:noreply, put_flash(socket, :error, "Couldn't save that answer. Please try again.")}
  end

  def handle_event("set_config", params, socket) do
    Game.set_config(socket.assigns.code, config_overrides(params))
    {:noreply, socket}
  end

  def handle_event("start", _params, socket) do
    case Game.start_game(socket.assigns.code) do
      :ok ->
        {:noreply, socket}

      {:error, :not_eligible} ->
        {:noreply, put_flash(socket, :error, ineligible_message(socket.assigns.view))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, start_error(reason))}
    end
  end

  def handle_event("skip_song", _params, socket) do
    Game.skip_song(socket.assigns.code)
    {:noreply, socket}
  end

  def handle_event("play_again", _params, socket) do
    Game.play_again(socket.assigns.code)
    {:noreply, assign(socket, playlist_open?: false, finale_seen?: false)}
  end

  def handle_event("toggle_playlist", _params, socket) do
    # The host is past the finale once they reach for a button: coming back
    # from the playlist shows the board as it stands, not the count-up again.
    {:noreply,
     assign(socket, playlist_open?: not socket.assigns.playlist_open?, finale_seen?: true)}
  end

  # Ending the game broadcasts `{:game_ended, _}`, which takes every host
  # screen, this one included, back to the start.
  def handle_event("exit_game", _params, socket) do
    case Game.end_game(socket.assigns.code) do
      :ok -> {:noreply, socket}
      {:error, _reason} -> {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  def handle_event("song_ended", _params, socket) do
    Game.song_ended(socket.assigns.code)
    {:noreply, socket}
  end

  def handle_event("playback_ready", _params, socket) do
    {:noreply, assign(socket, playback_ready?: true, playback_error: nil)}
  end

  def handle_event("playback_error", params, socket) do
    provider_id =
      case socket.assigns.view do
        %{music: %{id: id}} -> id
        _ -> nil
      end

    {:noreply,
     assign(socket,
       playback_ready?: false,
       playback_error: Music.playback_error_message(provider_id, params)
     )}
  end

  # Connect a provider on click: `:none` providers connect on the spot,
  # `:oauth_redirect` ones send the host through the OAuth round-trip.
  def handle_event("connect_music", %{"provider" => provider_id}, socket) do
    case Music.fetch_provider(provider_id) do
      {:ok, provider} -> connect_music(provider, socket)
      :error -> {:noreply, put_flash(socket, :error, "Unknown music service.")}
    end
  end

  def handle_event("connect_music", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unknown music service.")}
  end

  # How many of the night's songs the final screen lists.
  @playlist_shown 10

  @host_settings ~w(answer_timer_s vote_delay_s vote_timer_s questions_per_player
                    subrounds_enabled? allow_vote_change? min_players quick_reveals?
                    name_non_voters? show_places? final_suspense?)

  # Forward only the setting the host just changed. The form posts every field,
  # and untouched ones still hold player-count-derived defaults — sending them
  # would pin those defaults as overrides (e.g. an empty lobby's 15 questions
  # per player sticking after 8 people join).
  defp config_overrides(%{"_target" => [field | _]} = params) when field in @host_settings do
    Map.take(params, [field])
  end

  defp config_overrides(_params), do: %{}

  # What the closing card remembers of the game: who took it.
  defp closing(view) do
    board = Standings.rank(view.players, view.scores)

    line =
      case winner_rows(board) do
        [] ->
          nil

        [winner] ->
          "#{winner.name} took it with #{winner.score}"

        winners when length(winners) == length(board) ->
          nil

        [%{score: score} | _] = winners ->
          "#{join_names(Enum.map(winners, & &1.name))} shared it on #{score}"
      end

    %{line: line}
  end

  defp ended_message(:host_ended), do: "Thanks for playing."
  defp ended_message(:idle), do: "That game closed after sitting idle."
  defp ended_message(_reason), do: "That game has ended."

  defp start_error(:not_enough_players), do: "Not enough players have joined yet."
  defp start_error(:not_authenticated), do: "Connect a music service first."
  defp start_error(:already_started), do: "The game has already started."
  defp start_error(_), do: "Couldn't start the game. Please try again."

  defp connect_music(provider, socket) do
    case provider.connect_kind() do
      :none ->
        with {:ok, auth} <- provider.connect(%{}),
             :ok <- Game.set_music(socket.assigns.code, provider.id(), auth) do
          {:noreply, announce_connected(socket, provider, auth)}
        else
          {:error, :not_lobby} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "The game has started — you can't switch music service now."
             )}

          _ ->
            {:noreply, put_flash(socket, :error, "Couldn't connect #{provider.name()}.")}
        end

      :oauth_redirect ->
        {:noreply, redirect(socket, to: ~p"/auth/#{provider.id()}?code=#{socket.assigns.code}")}
    end
  end

  # A connection that worked needs no announcement: the prompt closes and the
  # top bar names the service. One that can't play full songs does.
  defp announce_connected(socket, provider, auth) do
    if provider.eligible?(auth),
      do: socket,
      else: put_flash(socket, :error, provider.ineligible_message())
  end

  # =========================================================================
  # Playback token
  # =========================================================================

  defp assign_playback(socket) do
    if ref = socket.assigns.refresh_timer, do: Process.cancel_timer(ref)

    case usable_music(socket.assigns.view) do
      {:ok, provider, auth} ->
        auth = ensure_fresh_auth(socket.assigns.code, provider, auth)

        assign(reset_player_status(socket, provider.id()),
          music_status: :ok,
          music_provider: provider.id(),
          music_video?: provider.video?(),
          music_config: Jason.encode!(provider.client_config(auth)),
          refresh_timer: schedule_refresh(Music.refresh_delay_ms(auth))
        )

      {:unavailable, reason} ->
        assign(socket,
          music_status: {:unavailable, reason},
          music_provider: nil,
          music_video?: false,
          music_config: "{}",
          playback_ready?: false,
          refresh_timer: nil
        )
    end
  end

  # A different provider means a new player element: its readiness and errors
  # are not the previous one's.
  defp reset_player_status(socket, provider_id) do
    if socket.assigns[:music_provider] == provider_id,
      do: socket,
      else: assign(socket, playback_ready?: false, playback_error: nil)
  end

  defp usable_music(%{music: %{id: id, eligible?: true}, music_auth: auth}) do
    case Music.fetch_provider(id) do
      {:ok, provider} -> {:ok, provider, auth}
      :error -> {:unavailable, "That music service isn't available on this server."}
    end
  end

  defp usable_music(%{music: %{eligible?: false}} = view),
    do: {:unavailable, ineligible_message(view)}

  defp usable_music(_view), do: {:unavailable, "No music service is connected."}

  defp ineligible_message(%{music: %{id: id}}) do
    case Music.fetch_provider(id) do
      {:ok, provider} -> provider.ineligible_message()
      :error -> "That music account can't play full songs."
    end
  end

  defp ineligible_message(_view), do: "Connect a music service first."

  defp music_of(%{music: music, music_auth: auth}), do: {music, auth}
  defp music_of(_view), do: nil

  # Refreshes (and stores) the host's credentials if they are about to expire.
  defp ensure_fresh_auth(code, provider, auth) do
    case Music.refresh_if_due(provider, auth) do
      {fresh, true} ->
        Game.set_music(code, provider.id(), fresh)
        fresh

      {auth, false} ->
        auth
    end
  end

  defp schedule_refresh(nil), do: nil
  defp schedule_refresh(ms), do: Process.send_after(self(), :refresh_token, ms)

  defp qr_svg(url) do
    url
    |> EQRCode.encode()
    |> EQRCode.svg(width: 300, background_color: "#f2eee4", color: "#171715")
  end

  # The URI that should be playing right now: the current round's song, which
  # keeps playing through voting and the reveal until the next round starts.
  defp play_uri(%{phase: :playing, round: %{song: %{uri: uri}}}) when is_binary(uri),
    do: uri

  defp play_uri(_view), do: ""

  # Changes every round, so the hook restarts a track that repeats back to back.
  defp play_round(%{phase: :playing, subround_index: sub, round: %{index: index}}),
    do: "#{sub}-#{index}"

  defp play_round(_view), do: ""

  # The size a video player takes on screen. The playing layout reserves this
  # much room (in place of the album art) and the player is placed over it.
  # Never wider than the screen minus the layout's side padding.
  defp video_frame_class, do: "aspect-video w-[min(28rem,calc(100vw-6rem))] xl:w-[30rem]"

  # Audio providers never show their player. A video provider's player is
  # placed over the room the playing layout reserves for it: that layout pads
  # 6rem above and, for a video provider, puts the reserved frame first, at the
  # top of the left column. It is positioned in the stage
  # (`.jam-stage` is `position: relative`), not fixed to the viewport, so it
  # scrolls with the layout it sits over.
  defp player_class(false, _playing?), do: "hidden"

  defp player_class(true, false),
    do: ["pointer-events-none absolute left-0 top-0 -z-10 opacity-0", video_frame_class()]

  defp player_class(true, true) do
    [
      "absolute z-20 left-12 top-24 overflow-hidden rounded-3xl bg-black shadow-2xl",
      "lg:left-20",
      video_frame_class()
    ]
  end

  # Lobby: only real player failures (missing connection is handled by the
  # connect prompt). In game: anything that stops audio.
  defp playback_banner(assigns) do
    cond do
      assigns.view.phase == :finished -> nil
      assigns.playback_error -> assigns.playback_error
      assigns.view.phase == :lobby -> nil
      match?({:unavailable, _}, assigns.music_status) -> elem(assigns.music_status, 1)
      true -> nil
    end
  end

  # =========================================================================
  # Music services
  # =========================================================================

  # Every provider the host can connect, with its status in this room.
  defp music_services(view, code) do
    for provider <- Music.providers() do
      status = service_status(provider, view)
      # Only the connected service has an account to ask or warn about.
      auth = if status == :connected, do: view.music_auth

      %{
        id: provider.id(),
        name: provider.name(),
        requirement: provider.requirement(),
        ineligible_message: provider.ineligible_message(),
        status: status,
        question: Music.account_question(provider.id(), auth),
        warning: Music.warning(provider.id(), auth),
        connect_href:
          if(provider.connect_kind() == :oauth_redirect,
            do: ~p"/auth/#{provider.id()}?code=#{code}"
          )
      }
    end
  end

  defp service_status(provider, view) do
    provider_id = provider.id()

    case view.music do
      %{id: ^provider_id, eligible?: eligible?} ->
        if eligible?, do: :connected, else: :ineligible

      _ ->
        if provider.configured?(), do: :disconnected, else: :unconfigured
    end
  end

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(%{view: nil} = assigns) do
    ~H"""
    <div data-theme="jam"><Layouts.flash_group flash={@flash} /></div>
    <div data-theme="jam" class="jam-stage jam-tv min-h-screen flex items-center px-12 lg:px-20">
      <div class="space-y-6">
        <img src={~p"/images/whose-jam-logo.svg"} alt="Whose Jam" class="w-56 -ml-4" />
        <h1 class="font-display text-6xl">No game here</h1>
        <p class="text-2xl text-jam-cream/60">Room {@code} isn't live.</p>
        <.link navigate={~p"/"} class="jam-btn">Back to start</.link>
      </div>
    </div>
    """
  end

  def render(%{closing: %{}} = assigns) do
    ~H"""
    <div
      data-theme="jam"
      id="closing-card"
      class="jam-stage jam-tv grid min-h-screen place-items-center px-20"
    >
      <div class="jam-rise flex flex-col items-center gap-8 text-center">
        <img src={~p"/images/whose-jam-logo.svg"} alt="Whose Jam" class="w-[26rem]" />
        <h1 class="font-display text-7xl">Thanks for playing</h1>
        <p :if={@closing.line} class="text-4xl font-bold text-jam-cream/75">{@closing.line}</p>
        <.link
          id="host-another"
          navigate={~p"/?host"}
          class="jam-btn jam-rise jam-late mt-4 text-3xl"
        >
          Host another game
        </.link>
      </div>
    </div>
    """
  end

  def render(assigns) do
    services = music_services(assigns.view, assigns.code)
    active_service = Enum.find(services, &(&1.status == :connected))

    assigns =
      assign(assigns,
        banner: playback_banner(assigns),
        services: services,
        active_service: active_service,
        art_url: current_art(assigns.view),
        board: Standings.rank(assigns.view.players, assigns.view.scores),
        show_music_prompt?:
          assigns.view.phase == :lobby and is_nil(active_service) and
            not assigns.music_prompt_dismissed? and not assigns.settings_open?,
        show_music_question?:
          assigns.view.phase == :lobby and unanswered_question?(active_service) and
            not assigns.music_question_dismissed? and not assigns.settings_open?
      )

    ~H"""
    <%!-- Inside the theme, so a notice wears the game's colours. --%>
    <div data-theme="jam"><Layouts.flash_group flash={@flash} /></div>

    <div
      data-theme="jam"
      class={
        [
          "jam-stage jam-tv min-h-screen overflow-hidden",
          # The host's quick-reveals choice retimes every beat (app.css).
          @view.config[:quick_reveals?] && "jam-quick"
        ]
      }
    >
      <%!-- Keyed by provider, so switching service remounts the player. A video
           provider's player sits where the album art would be while a song
           plays; the rest of the time it stays rendered but invisible, because
           an embedded player inside `display: none` may never start.

           It must stay the FIRST child here. If a conditional sibling is
           inserted ahead of it (the ambient artwork appears exactly when a
           song starts), the DOM patch re-inserts this element, and a
           re-inserted iframe reloads: the embedded player comes back empty and
           deaf to the play command. --%>
      <div
        :if={@music_status == :ok}
        id={"music-player-#{@music_provider}"}
        phx-hook="MusicPlayer"
        data-provider={@music_provider}
        data-config={@music_config}
        data-uri={play_uri(@view)}
        data-round={play_round(@view)}
        class={player_class(@music_video?, play_uri(@view) != "")}
      >
        <div
          :if={@music_video?}
          id={"music-video-#{@music_provider}"}
          phx-update="ignore"
          data-music-video
          class="size-full"
        >
        </div>
      </div>

      <%!-- Apple Music–style ambience: the current song's artwork tints the room. --%>
      <div :if={@art_url} class="jam-ambient" aria-hidden="true">
        <img src={@art_url} alt="" />
      </div>

      {top_bar(assigns)}

      <div :if={@banner} class="fixed bottom-6 right-6 z-30 max-w-md">
        <div class="flex items-start gap-3 rounded-2xl bg-jam-orange px-4 py-3 text-sm text-jam-ink font-bold shadow-xl">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
          <span>Playback unavailable — {@banner}</span>
        </div>
      </div>

      <%= case @view.phase do %>
        <% :lobby -> %>
          {lobby(assigns)}
        <% :answering -> %>
          {answering(assigns)}
        <% :playing -> %>
          {playing(assigns)}
        <% :finished -> %>
          {finished(assigns)}
      <% end %>

      {music_prompt(assigns)}
      {music_question(assigns)}
      {settings_panel(assigns)}
    </div>
    """
  end

  # ---- host bar -----------------------------------------------------------

  defp top_bar(assigns) do
    ~H"""
    <header class="fixed top-0 inset-x-0 z-40 h-20 flex items-center justify-between gap-4 px-12 lg:px-20">
      <div class="flex items-center gap-4 min-w-0">
        <img src={~p"/images/whose-jam-logo.svg"} alt="Whose Jam" class="h-16 -ml-3 shrink-0" />
        <%!-- Where to join stays readable all game, for anyone who turns up
             late: the address, ending in the room code. --%>
        <span :if={@view.phase != :lobby} class="flex min-w-0 items-baseline gap-4 font-bold">
          <span class="truncate text-xl text-jam-cream/60">{@view.theme.name}</span>
          <span class="flex shrink-0 items-baseline gap-1.5">
            <span id="join-at" class="text-2xl text-jam-cream/70">
              {String.replace_suffix(display_url(@join_url), @code, "")}
            </span>
            <span id="room-code" class="font-display text-4xl tracking-[0.14em] text-jam-cream">
              {@code}
            </span>
          </span>
        </span>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <button
          type="button"
          phx-click="open_settings"
          class={[
            "jam-chip text-sm cursor-pointer",
            !@active_service && "!bg-jam-orange !text-jam-ink"
          ]}
        >
          <%= if @active_service do %>
            <span class={[
              "inline-block size-2 rounded-full",
              if(@playback_ready?, do: "bg-jam-mint", else: "bg-jam-cream/40")
            ]} />
            {@active_service.name}
            <.icon
              :if={@active_service.warning}
              name="hero-exclamation-triangle"
              class="size-4 text-jam-orange"
            />
          <% else %>
            <.icon name="hero-musical-note" class="size-4" /> Connect music
          <% end %>
        </button>

        <button
          :if={@view.phase == :playing}
          type="button"
          phx-click="skip_song"
          data-confirm="Skip this song and move on?"
          class="jam-chip text-sm cursor-pointer"
        >
          <.icon name="hero-forward" class="size-4" /> Skip
        </button>

        <button
          type="button"
          phx-click="open_settings"
          aria-label="Settings"
          class="jam-chip !px-2.5 cursor-pointer"
        >
          <.icon name="hero-cog-6-tooth" class="size-5" />
        </button>
      </div>
    </header>
    """
  end

  # ---- music service prompt ----------------------------------------------

  defp music_prompt(assigns) do
    ~H"""
    <.modal
      :if={@show_music_prompt?}
      id="music-prompt-modal"
      on_close="dismiss_music_prompt"
      class="max-w-lg"
      body_class="space-y-5"
    >
      <div class="space-y-2">
        <h2 class="font-display text-3xl">Connect your music</h2>
        <p class="text-base-content/70">
          This screen plays every song the players pick. Connect a music service before you start.
        </p>
      </div>
      {music_service_list(assigns)}
      <div class="modal-action mt-0">
        <button type="button" phx-click="dismiss_music_prompt" class="jam-btn jam-btn-ghost text-sm">
          Not now
        </button>
      </div>
    </.modal>
    """
  end

  # ---- account question ---------------------------------------------------

  # Asked once, right after the account is connected. Dismissing it leaves the
  # question unanswered: the provider's warning then assumes the worse case,
  # and Settings still offers the answer.
  defp music_question(assigns) do
    ~H"""
    <.modal
      :if={@show_music_question?}
      id="music-question-modal"
      on_close="dismiss_music_question"
      class="max-w-lg"
      body_class="space-y-5"
    >
      <div class="space-y-2">
        <p class="jam-eyebrow">{@active_service.name} connected</p>
        <h2 class="font-display text-3xl">{@active_service.question.prompt}</h2>
        <p class="text-base-content/70">{@active_service.question.detail}</p>
      </div>
      <div class="modal-action mt-0">
        <button
          type="button"
          id="music-question-no"
          phx-click="answer_music_question"
          phx-value-answer="no"
          class="jam-btn jam-btn-ghost text-sm"
        >
          No, or not sure
        </button>
        <button
          type="button"
          id="music-question-yes"
          phx-click="answer_music_question"
          phx-value-answer="yes"
          class="jam-btn text-sm"
        >
          Yes
        </button>
      </div>
    </.modal>
    """
  end

  defp unanswered_question?(%{question: %{answer: nil}}), do: true
  defp unanswered_question?(_service), do: false

  defp music_service_list(assigns) do
    ~H"""
    <ul class="space-y-3">
      <li
        :for={service <- @services}
        class="space-y-3 rounded-box border border-jam-cream/10 bg-base-200 p-4"
      >
        <div class="flex items-center gap-4">
          <%!-- Each service its own mark: its initial, so they tell apart. --%>
          <div class={[
            "grid place-items-center size-11 rounded-full font-display text-xl shrink-0",
            if(service.status == :unconfigured,
              do: "bg-base-300 text-base-content/50",
              else: "bg-jam-pink text-white"
            )
          ]}>
            {String.first(service.name)}
          </div>
          <div class="flex-1 min-w-0">
            <p class="font-display text-lg">{service.name}</p>
            <p class={["text-sm", service_status_class(service.status)]}>
              {service_status_text(service)}
            </p>
          </div>
          <a
            :if={service.connect_href && service.status != :unconfigured}
            href={service.connect_href}
            class={["jam-btn text-sm !px-4 !py-2", service.status == :connected && "jam-btn-ghost"]}
          >
            {service_action(service.status)}
          </a>
          <button
            :if={is_nil(service.connect_href) && service.status != :unconfigured}
            type="button"
            phx-click="connect_music"
            phx-value-provider={service.id}
            class={["jam-btn text-sm !px-4 !py-2", service.status == :connected && "jam-btn-ghost"]}
          >
            {service_action(service.status)}
          </button>
        </div>

        <div
          :if={service.question}
          id={"music-question-#{service.id}"}
          class="flex flex-wrap items-center justify-between gap-3 border-t border-jam-cream/10 pt-3"
        >
          <p class="text-sm text-base-content/80">{service.question.prompt}</p>
          <div class="flex gap-2">
            <button
              :for={{label, value, answer} <- [{"Yes", "yes", true}, {"No", "no", false}]}
              type="button"
              phx-click="answer_music_question"
              phx-value-answer={value}
              aria-pressed={to_string(service.question.answer == answer)}
              class={[
                "jam-chip text-sm cursor-pointer transition-colors",
                service.question.answer == answer && "jam-chip-on"
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <p :if={service.warning} class="flex items-start gap-2 text-sm text-warning">
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 mt-0.5" />
          <span>{service.warning}</span>
        </p>
      </li>
    </ul>
    """
  end

  defp service_status_text(%{status: :connected, name: name}), do: "Connected — #{name} is ready."

  defp service_status_text(%{status: :ineligible, ineligible_message: message}), do: message

  defp service_status_text(%{status: :unconfigured}),
    do: "Not set up on this server yet."

  defp service_status_text(%{requirement: requirement}), do: requirement

  defp service_status_class(:connected), do: "text-success"
  defp service_status_class(:ineligible), do: "text-error"
  defp service_status_class(_), do: "text-base-content/60"

  defp service_action(:connected), do: "Switch account"
  defp service_action(:ineligible), do: "Reconnect"
  defp service_action(_), do: "Connect"

  # ---- settings panel ----------------------------------------------------

  defp settings_panel(assigns) do
    assigns = assign(assigns, estimate: runtime_estimate(assigns.view))

    ~H"""
    <.modal
      :if={@settings_open?}
      id="settings-modal"
      on_close="close_settings"
      class="max-w-2xl max-h-[88vh]"
      body_class="space-y-7"
    >
      <div class="flex items-center justify-between">
        <h2 class="font-display text-3xl">Settings</h2>
        <button
          type="button"
          phx-click="close_settings"
          aria-label="Close settings"
          class="jam-chip !px-2.5 cursor-pointer"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <section class="space-y-3">
        <h3 class="jam-eyebrow">Music service</h3>
        {music_service_list(assigns)}
        <p :if={@active_service} class="text-sm text-base-content/60">
          <%= if @playback_ready? do %>
            This screen is ready to play the music.
          <% else %>
            Getting this screen ready to play the music…
          <% end %>
        </p>
      </section>

      <section class="space-y-3">
        <div class="flex items-center justify-between">
          <h3 class="jam-eyebrow">Game</h3>
          <span class="text-sm text-base-content/60">
            Estimated length: <span class="font-bold text-jam-orange">~{@estimate} min</span>
          </span>
        </div>

        <p :if={@view.phase != :lobby} class="text-sm text-base-content/60">
          Game settings are locked once the game starts.
        </p>

        <form phx-change="set_config" class="grid gap-2 sm:grid-cols-2">
          <fieldset disabled={@view.phase != :lobby} class="contents">
            <.input
              type="number"
              id="answer_timer_s"
              name="answer_timer_s"
              label="Time to pick songs (s)"
              value={@view.config.answer_timer_s}
              min={Config.range(:answer_timer_s).first}
              max={Config.range(:answer_timer_s).last}
            />
            <.input
              type="number"
              id="vote_delay_s"
              name="vote_delay_s"
              label="Listen before voting opens (s)"
              value={@view.config.vote_delay_s}
              min={Config.range(:vote_delay_s).first}
              max={Config.range(:vote_delay_s).last}
            />
            <.input
              type="number"
              id="vote_timer_s"
              name="vote_timer_s"
              label="Voting time (s)"
              value={@view.config.vote_timer_s}
              min={Config.range(:vote_timer_s).first}
              max={Config.range(:vote_timer_s).last}
            />
            <.input
              type="number"
              id="questions_per_player"
              name="questions_per_player"
              label="Prompts per player"
              value={@view.config.questions_per_player}
              min={Config.range(:questions_per_player).first}
              max={Config.range(:questions_per_player).last}
            />
            <.input
              type="select"
              id="min_players"
              name="min_players"
              label="Players needed to start"
              value={@view.config.min_players}
              options={Enum.map(Config.range(:min_players), &{Integer.to_string(&1), &1})}
            />
            <div class="flex flex-col justify-end gap-1">
              <.input
                type="checkbox"
                id="subrounds_enabled?"
                name="subrounds_enabled?"
                label="Play each style as its own sub-round"
                checked={@view.config.subrounds_enabled?}
              />
              <.input
                type="checkbox"
                id="allow_vote_change?"
                name="allow_vote_change?"
                label="Allow changing a vote"
                checked={@view.config.allow_vote_change?}
              />
            </div>
          </fieldset>
        </form>
      </section>

      <%!-- How the screens tell the game, for rooms that like it another
           way. None of these change the scoring or the timers. --%>
      <section class="space-y-3">
        <h3 class="jam-eyebrow">On the screens</h3>
        <form phx-change="set_config" id="presentation-settings" class="grid gap-1 sm:grid-cols-2">
          <fieldset disabled={@view.phase != :lobby} class="contents">
            <.input
              type="checkbox"
              id="quick_reveals?"
              name="quick_reveals?"
              label="Quick reveals: everything at once"
              checked={@view.config.quick_reveals?}
            />
            <.input
              type="checkbox"
              id="name_non_voters?"
              name="name_non_voters?"
              label="Name who didn't vote"
              checked={@view.config.name_non_voters?}
            />
            <.input
              type="checkbox"
              id="show_places?"
              name="show_places?"
              label="Show every place on the score strip"
              checked={@view.config.show_places?}
            />
            <.input
              type="checkbox"
              id="final_suspense?"
              name="final_suspense?"
              label="Hide totals during the final round"
              checked={@view.config.final_suspense?}
            />
          </fieldset>
        </form>
      </section>
    </.modal>
    """
  end

  # ---- lobby --------------------------------------------------------------

  # `raw/1` is safe here: EQRCode.svg/2 emits only numeric rect coordinates and
  # the literal colours set in qr_svg/1, so no player data reaches the markup.
  # It sits in its own component so the Sobelow skip covers just this one call.
  # sobelow_skip ["XSS.Raw"]
  defp qr_code(assigns), do: ~H"{raw(@svg)}"

  defp lobby(assigns) do
    player_count = length(assigns.view.players)

    assigns =
      assign(assigns,
        player_count: player_count,
        max_players: Game.max_players(),
        open_seats: max(Game.max_players() - player_count, 0),
        min_players: assigns.view.config.min_players
      )

    ~H"""
    <div class="min-h-screen grid content-center gap-12 px-12 lg:px-20 pt-28 pb-16 xl:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] xl:items-center xl:gap-20">
      <div class="space-y-10">
        <div class="space-y-3">
          <p class="jam-eyebrow">Tonight's theme</p>
          <h1 class="font-display text-6xl xl:text-7xl leading-none">{@view.theme.name}</h1>
          <p class="max-w-2xl text-xl xl:text-2xl text-jam-cream/70">{@view.theme.description}</p>
          <%!-- The one rule that changes how you pick: fooling people scores. --%>
          <p id="how-to-score" class="space-y-1 pt-2 text-2xl xl:text-3xl font-bold text-jam-cream">
            <span class="block">
              <span class="font-display text-jam-mint">+1</span> for each correct guess.
            </span>
            <span class="block">
              <span class="font-display text-jam-orange">+1</span> for each player your song fools.
            </span>
            <span class="block">
              <span class="font-display text-jam-orange">+1</span>
              if you call who takes the blame for your song.
            </span>
          </p>
        </div>

        <div class="flex flex-col sm:flex-row sm:items-center gap-10">
          <div class="shrink-0 rounded-2xl bg-jam-cream p-4 [&>svg]:size-64">
            <.qr_code svg={@qr_svg} />
          </div>
          <div class="space-y-2">
            <p class="jam-eyebrow">Room code</p>
            <p class="font-display text-9xl leading-none tracking-[0.1em] whitespace-nowrap">
              {@view.code}
            </p>
            <p class="pt-3 text-xl xl:text-2xl text-jam-cream/70">
              Scan to join, or go to <br />
              <span
                id="join-url"
                class="whitespace-nowrap text-2xl xl:text-3xl font-bold text-jam-cream"
              >
                {display_url(@join_url)}
              </span>
            </p>
          </div>
        </div>
      </div>

      <div class="jam-panel space-y-8 p-8 xl:p-10">
        <div class="flex items-baseline justify-between">
          <p class="jam-eyebrow">Players</p>
          <p id="player-count" class="font-display text-4xl tabular-nums">
            {@player_count}<span class="text-jam-cream/35">/{@max_players}</span>
          </p>
        </div>

        <ul id="lobby-players" class="grid grid-flow-row-dense grid-cols-2 gap-3">
          <li
            :for={p <- @view.players}
            id={"seat-#{p.id}"}
            class={[
              "jam-pop truncate whitespace-nowrap rounded-2xl bg-jam-cream px-5 py-3 font-display text-3xl leading-tight text-jam-ink",
              long_name?(p.name) && "col-span-2",
              p.connected? || "opacity-40"
            ]}
          >
            {p.name}
          </li>
          <li
            :for={seat <- 1..@open_seats//1}
            id={"open-seat-#{seat}"}
            class="rounded-2xl border-2 border-dashed border-jam-cream/15 px-5 py-3 text-3xl"
            aria-hidden="true"
          >
            &nbsp;
          </li>
        </ul>

        <div :if={@view.audience != []} class="space-y-3">
          <p class="jam-eyebrow">Audience · {length(@view.audience)}</p>
          <div class="flex flex-wrap gap-2">
            <span :for={p <- @view.audience} class="jam-chip text-xl">{p.name}</span>
          </div>
        </div>

        <div class="space-y-4">
          <button
            phx-click="start"
            disabled={@player_count < @min_players or is_nil(@active_service)}
            class="jam-btn w-full text-3xl"
          >
            Start game
          </button>
          <%= cond do %>
            <% is_nil(@active_service) -> %>
              <button
                type="button"
                phx-click="open_settings"
                class="block w-full text-center text-xl font-bold text-jam-orange underline underline-offset-4 cursor-pointer"
              >
                Connect a music service to start
              </button>
            <% @player_count < @min_players -> %>
              <p class="text-center text-2xl text-jam-cream/70">
                {players_needed(@min_players - @player_count)}
              </p>
            <% true -> %>
              <p class="text-center text-2xl text-jam-cream/70">
                Start whenever everyone's in.
              </p>
          <% end %>
        </div>

        <div
          :if={@active_service && @active_service.warning}
          id="music-warning"
          class="flex items-start gap-3 rounded-2xl border border-jam-orange/40 bg-jam-orange/10 px-5 py-4 text-jam-cream/90"
        >
          <.icon name="hero-exclamation-triangle" class="size-6 shrink-0 text-jam-orange" />
          <p class="text-lg">
            {@active_service.warning}
            <button
              type="button"
              phx-click="open_settings"
              class="ml-1 font-bold text-jam-orange underline underline-offset-4 cursor-pointer"
            >
              Change
            </button>
          </p>
        </div>
      </div>
    </div>
    """
  end

  # A seat's name on one line, at the size of everyone else's: a long one
  # takes the whole row rather than shrinking or breaking.
  defp long_name?(name), do: String.length(name) > 12

  defp players_needed(1), do: "Waiting for 1 more player"
  defp players_needed(n), do: "Waiting for #{n} more players"

  # The join address as someone would type it: no scheme.
  defp display_url(url), do: String.replace(url, ~r{^https?://}, "")

  # ---- answering ----------------------------------------------------------

  # The same seats as the lobby: each fills in as its player locks in.
  defp answering(assigns) do
    progress = (assigns.view.answering && assigns.view.answering.progress) || %{}

    seats =
      for p <- assigns.view.players do
        prog = Map.get(progress, p.id, %{submitted: 0, total: 0})
        %{id: p.id, name: p.name, prog: prog, done?: prog.submitted >= prog.total}
      end

    done = Enum.count(seats, & &1.done?)

    assigns =
      assign(assigns, seats: seats, done: done, all_in?: seats != [] and done == length(seats))

    ~H"""
    <div class="min-h-screen grid content-center gap-12 px-12 lg:px-20 pt-28 pb-12 xl:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] xl:items-center xl:gap-20">
      <div class="space-y-12">
        <div class="space-y-3">
          <p :if={@view.subround_total > 1} class="jam-eyebrow">
            Sub-round {@view.subround_index + 1} of {@view.subround_total}
          </p>
          <%!-- The last pick landing is a moment of its own (the server holds
               this screen briefly once everyone is in). --%>
          <h1 :if={!@all_in?} class="font-display text-7xl xl:text-8xl leading-none">Heads down</h1>
          <p :if={!@all_in?} class="text-2xl xl:text-3xl text-jam-cream/70">
            Everyone's picking songs on their own screens.
          </p>
          <h1
            :if={@all_in?}
            id="all-in"
            class="jam-pop origin-left font-display text-7xl xl:text-8xl leading-none text-jam-mint"
          >
            Everyone's in
          </h1>
          <p :if={@all_in?} class="jam-rise text-2xl xl:text-3xl text-jam-cream/70">
            Eyes up. Here comes the music.
          </p>
        </div>

        <div :if={@view.answering && !@all_in?} class="space-y-1">
          <p class="jam-eyebrow">Time left</p>
          <p
            id="answer-countdown"
            phx-hook="Countdown"
            data-deadline={@view.answering.deadline_ms}
            class="font-display text-9xl leading-none tabular-nums text-jam-orange"
          >
          </p>
        </div>
      </div>

      <div :if={@view.answering} class="jam-panel space-y-8 p-8 xl:p-10">
        <div class="flex items-baseline justify-between">
          <p class="jam-eyebrow">Locked in</p>
          <p id="locked-in-count" class="font-display text-4xl tabular-nums">
            {@done}<span class="text-jam-cream/35">/{length(@seats)}</span>
          </p>
        </div>

        <ul id="answering-players" class="grid grid-flow-row-dense grid-cols-2 gap-3">
          <li
            :for={seat <- @seats}
            id={"picking-#{seat.id}"}
            class={[
              "relative flex items-center justify-between gap-3 overflow-hidden rounded-2xl border-2 px-5 py-3 font-display text-3xl",
              long_name?(seat.name) && "col-span-2",
              if(seat.done?,
                do: "jam-bump border-jam-mint bg-jam-mint text-jam-ink",
                else: "border-jam-cream/15 text-jam-cream/70"
              )
            ]}
          >
            <span class="min-w-0 truncate whitespace-nowrap leading-tight">{seat.name}</span>
            <%!-- The tick's place is kept from the start, so a name never
                 reflows when it lands. --%>
            <.icon
              :if={seat.prog.total <= 1 or seat.done?}
              name="hero-check"
              class={["size-7 shrink-0", !seat.done? && "invisible"]}
            />
            <span :if={!seat.done? and seat.prog.total > 1} class="shrink-0 text-2xl tabular-nums">
              {seat.prog.submitted}/{seat.prog.total}
            </span>
            <%!-- With several prompts each, a thin bar shows how far along. --%>
            <span
              :if={!seat.done? and seat.prog.total > 1}
              class="absolute inset-x-0 bottom-0 h-1 bg-jam-cream/10"
              aria-hidden="true"
            >
              <span
                class="block h-full bg-jam-pink transition-[width] duration-500"
                style={progress_style(seat.prog)}
              ></span>
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # ---- playing ------------------------------------------------------------

  defp playing(%{view: %{round: nil}} = assigns) do
    ~H"""
    <div class="min-h-screen flex items-center px-12 lg:px-20">
      <p class="font-display text-4xl text-jam-cream/70">Loading the next song…</p>
    </div>
    """
  end

  # What the song was picked for runs across the top, the biggest thing on
  # screen for the whole round: it is what the room is talking about. Under
  # it, the song on the left never moves, and what the room is doing right
  # now — listen, vote, find out — takes the right. The scores run along the
  # bottom.
  #
  # A video provider's player (see render/1 and player_class/2) is placed over
  # a frame this layout reserves. Its place must not depend on how many lines
  # the prompt takes, so with a video the frame comes first, at the top of the
  # left column (the layout pads 6rem above), and the prompt moves to the top
  # of the right column.
  defp playing(assigns) do
    assigns = assign(assigns, :round_key, play_round(assigns.view))

    ~H"""
    <%!-- Exactly the screen's height: whatever a round shows, the score
         strip stays on screen at the bottom. --%>
    <div class="h-screen flex flex-col gap-6 px-12 lg:px-20 pt-24 pb-8">
      <%!-- Opens each round, then clears for the song. Below the video player
           (z-20), which must never be covered. --%>
      <div
        :if={@view.round_state == :revealing}
        id={"round-card-#{@round_key}"}
        class={[
          "jam-round-card pointer-events-none absolute inset-0 z-10 grid place-items-center bg-jam-ink px-20",
          quick_card?(@view.round) && "jam-round-card-short"
        ]}
        aria-hidden="true"
      >
        <div class="jam-round-card-text max-w-[70rem] space-y-6 text-center">
          <p class="font-display text-9xl">
            Round {@view.round.index + 1}
            <span class="text-jam-cream/40">of {@view.round.total}</span>
          </p>
          <%!-- What the next song was picked for, so the card says something;
               a prompt's second song is framed as that, not read out again. --%>
          <p
            :if={@view.round.prompt && second_take?(@view.round)}
            class="jam-eyebrow !text-4xl !text-jam-cream/75"
          >
            Another pick for
          </p>
          <p
            :if={@view.round.prompt}
            class="font-display text-6xl leading-tight text-balance text-jam-cream"
          >
            {@view.round.prompt}
          </p>
        </div>
      </div>

      <%= if @music_video? do %>
        <div class="flex-1 min-h-0 flex flex-col gap-10 lg:flex-row lg:items-start lg:gap-16">
          <div class="shrink-0 space-y-6">
            <%!-- Holds the space the video player sits over. --%>
            <div class={video_frame_class()} aria-hidden="true"></div>
            {song(assigns)}
          </div>
          <div class="min-w-0 flex-1 space-y-10">
            {prompt_band(assigns)}
            {phase_panel(assigns)}
          </div>
        </div>
      <% else %>
        {prompt_band(assigns)}
        <div class={[
          "flex-1 min-h-0 overflow-hidden flex flex-col gap-10 lg:flex-row lg:gap-12",
          if(@view.round_state == :results, do: "lg:items-start", else: "lg:items-center")
        ]}>
          <%!-- The song is a poster: a sheet of egg-white paper laid on the
               stage, its cover printed on it and its name and artist set in
               ink, once, large enough to read from the sofa. While the room
               listens and votes it is the hero, a wide sheet with the words
               beside the cover; at the reveal it steps back to a small print
               and the answer takes the stage. --%>
          <div class="shrink-0 p-2">
            <.poster
              song={@view.round.song}
              art_id={"art-#{@round_key}"}
              size={if @view.round_state == :results, do: :small, else: :wide}
            />
          </div>
          <%!-- Beside it, what the room is doing right now. --%>
          <div class={[
            "min-w-0 flex-1",
            if(@view.round_state == :results, do: "space-y-7", else: "lg:py-2")
          ]}>
            {phase_panel(assigns)}
          </div>
        </div>
      <% end %>

      {score_strip(assigns)}
    </div>
    """
  end

  # The round's question as a label, and (in a guess-who round) the prompt the
  # song was picked for, large. A guess-question round keeps its prompt secret
  # until the reveal, so there the question itself is the headline.
  defp prompt_band(assigns) do
    ~H"""
    <figure id="round-prompt" class="space-y-3 border-l-4 border-jam-pink pl-6">
      <%!-- The round and its one clue (how many picked for this prompt), at
           a size and weight the sofa can read. --%>
      <figcaption class="flex items-center gap-3 jam-eyebrow !text-[1.75rem] !text-jam-cream/85">
        <span class="jam-eq" aria-hidden="true">
          <span></span><span></span><span></span><span></span>
        </span>
        Round {@view.round.index + 1} of {@view.round.total}
        <span :if={@view.round.prompt_take} id="prompt-take">
          · {take_label(@view.round.prompt_take)}
        </span>
        <%!-- When the reveal gives way to the next song, so nobody is caught
             reading. Up here it costs the reveal no room. --%>
        <span
          :if={@view.round_state == :results && @view.round.next_ms}
          id="next-up"
          class="jam-rise jam-beat-3 ml-auto"
        >
          {if @view.round.index + 1 < @view.round.total, do: "Next song in", else: "Final scores in"}
          <span
            id={"next-countdown-#{@view.round.index}"}
            phx-hook="Countdown"
            data-deadline={@view.round.next_ms}
            class="text-jam-cream tabular-nums"
          ></span>
        </span>
      </figcaption>
      <blockquote
        :if={@view.round.prompt}
        class={
          [
            "font-display leading-[1.1] line-clamp-2 text-balance",
            # A long prompt a size down, so it keeps to one line and the round
            # below it keeps its room.
            if(@view.round_state == :results or String.length(@view.round.prompt) > 50,
              do: "text-4xl",
              else: "text-5xl"
            )
          ]
        }
      >
        {@view.round.prompt}
      </blockquote>
      <p :if={!@view.round.prompt} class="font-display text-6xl leading-[1.1] text-jam-orange">
        {round_question(@view.round.style)}
      </p>
    </figure>
    """
  end

  # The song's name and artist, large beside its poster (or a video
  # provider's player) while it plays. It is the screen's heading.
  defp song(assigns) do
    ~H"""
    <div class="min-w-0">
      <h1 class="font-display text-[3.4rem] leading-[1.05] line-clamp-2 text-balance">
        {@view.round.song.name}
      </h1>
      <p class="mt-2 truncate text-[1.6rem] font-bold uppercase tracking-[0.12em] text-jam-cream/70">
        {@view.round.song.artist}
      </p>
    </div>
    """
  end

  attr :song, :map, required: true
  attr :art_id, :string, default: nil
  attr :size, :atom, default: :small, values: [:wide, :small]
  attr :heading?, :boolean, default: true

  # A song as a poster: its cover printed on a sheet of paper, its name and
  # artist set in ink, the sheet a touch askew and lifted off the stage
  # (`.jam-poster` in app.css). Wide (while the song plays) the words sit
  # beside the cover, large; small (at the reveal) they sit under it. Either
  # way the song's name is the screen's heading. Keyed by round (`art_id`),
  # so a new round never shows the last one's cover while its own loads.
  defp poster(%{size: :wide} = assigns) do
    ~H"""
    <figure class="jam-hand jam-poster flex w-[44rem] items-stretch gap-6 bg-jam-cream p-5 text-jam-ink">
      <img
        :if={@song[:album_art_url]}
        id={@art_id}
        src={@song.album_art_url}
        alt="Album art"
        class="size-[17rem] shrink-0 object-cover"
      />
      <div
        :if={!@song[:album_art_url]}
        class="grid size-[17rem] shrink-0 place-items-center bg-jam-ink/10"
        aria-hidden="true"
      >
        <.icon name="hero-musical-note" class="size-1/3 text-jam-ink/40" />
      </div>
      <%!-- The words sit at the foot of the sheet, as a print's do. --%>
      <figcaption class="flex min-w-0 flex-col justify-end pb-1">
        <h1 class="font-display text-[3.2rem] leading-[1.02] line-clamp-3 text-balance break-keep">
          {@song.name}
        </h1>
        <p class="mt-3 truncate text-[1.7rem] font-bold text-jam-ink/70">
          {@song.artist}
        </p>
      </figcaption>
    </figure>
    """
  end

  defp poster(assigns) do
    ~H"""
    <figure class="jam-hand jam-poster jam-pop w-64 bg-jam-cream p-3 text-jam-ink">
      <img
        :if={@song[:album_art_url]}
        id={@art_id}
        src={@song.album_art_url}
        alt="Album art"
        class="aspect-square w-full object-cover"
      />
      <div
        :if={!@song[:album_art_url]}
        class="grid aspect-square w-full place-items-center bg-jam-ink/10"
        aria-hidden="true"
      >
        <.icon name="hero-musical-note" class="size-1/3 text-jam-ink/40" />
      </div>
      <figcaption class="mt-2 space-y-1 px-1">
        <.dynamic_tag
          tag_name={if @heading?, do: "h1", else: "p"}
          class="font-display text-3xl leading-[1.05] line-clamp-2 break-keep"
        >
          {@song[:name] || @song[:song_name]}
        </.dynamic_tag>
        <p class="truncate text-xl font-bold text-jam-ink/70">
          {@song.artist}
        </p>
      </figcaption>
    </figure>
    """
  end

  defp phase_panel(assigns) do
    ~H"""
    <%= case @view.round_state do %>
      <% :revealing -> %>
        {listening(assigns)}
      <% :voting -> %>
        {voting(assigns)}
      <% :results -> %>
        {results(assigns)}
      <% _ -> %>
    <% end %>
    """
  end

  defp listening(assigns) do
    ~H"""
    <div id="tv-listening" class="jam-rise space-y-5 px-2">
      <div class="flex items-center gap-8">
        <%!-- What moves while a song plays. The song has the room: the clock
             is a quiet line, not a headline. --%>
        <span class="jam-eq jam-eq-lg text-7xl" aria-hidden="true">
          <span></span><span></span><span></span><span></span><span></span><span></span>
        </span>
        <div class="space-y-2">
          <p class="font-display text-5xl">Listen up</p>
          <p class="text-3xl text-jam-cream/75">
            Voting opens in
            <span
              id="votes-open-countdown"
              phx-hook="Countdown"
              data-deadline={@view.round.votes_open_ms}
              class="font-display text-5xl text-jam-cream tabular-nums"
            ></span>
          </p>
        </div>
      </div>
      <%!-- The same wait as a line that fills, to read from across the room
           without reading a clock. The hook draws it (see Progress in
           hooks/player.js), so the page never patches it mid-fill. --%>
      <div
        id={"listen-progress-#{@round_key}"}
        phx-hook="Progress"
        phx-update="ignore"
        data-deadline={@view.round.votes_open_ms}
        data-duration={@view.config.vote_delay_s * 1000}
        class="h-4 overflow-hidden rounded-full bg-jam-cream/15"
        aria-hidden="true"
      >
        <span class="block h-full origin-left rounded-full bg-gradient-to-r from-jam-pink to-jam-orange [transform:scaleX(0)]"></span>
      </div>
    </div>
    """
  end

  # Says who is in, never what they chose. Everyone has something to lock in,
  # the picker included (their guess at who the room will blame), so the names
  # give nothing away.
  defp voting(assigns) do
    received = assigns.view.round.votes_received
    expected = max(assigns.view.round.eligible_voters, received)
    all_in? = assigns.view.round.all_in?

    # The players the round waits for (connected, the picker too) not yet in.
    # The audience isn't called out: its chips go quiet on their own.
    waiting =
      for p <- assigns.view.players,
          p.connected?,
          p.id not in assigns.view.round.voters,
          do: p.name

    assigns =
      assign(assigns, received: received, expected: expected, all_in?: all_in?, waiting: waiting)

    ~H"""
    <div id="tv-voting" class="space-y-5">
      <%!-- Once everyone has voted there is nobody left to tell to. --%>
      <div
        :if={@all_in?}
        id="tv-all-in"
        class="jam-bump flex items-center justify-between gap-6 rounded-2xl bg-jam-night px-8 py-4 text-jam-cream ring-4 ring-inset ring-jam-cream/80"
      >
        <div class="flex items-center gap-5">
          <span class="jam-badge text-6xl !bg-none !bg-jam-cream !text-jam-ink" aria-hidden="true">
            <.icon name="hero-check" class="size-[0.5em]" />
          </span>
          <div>
            <%!-- This countdown is the reveal's held breath: when it runs
                 out the name is on screen, with no second wait after it.
                 Where votes can still change, it is the last chance to, as
                 the phones say too. --%>
            <p class="font-display text-5xl">
              {if @view.config.allow_vote_change?, do: "All in", else: "All votes in"}
            </p>
            <p :if={@view.config.allow_vote_change?} class="mt-1 text-3xl text-jam-cream/75">
              Last chance to switch.
            </p>
          </div>
        </div>
        <.tv_timer
          :if={@view.round.deadline_ms}
          id="reveal-countdown"
          label="Reveal in"
          deadline={@view.round.deadline_ms}
        />
      </div>
      <div
        :if={!@all_in?}
        id="tv-vote-now"
        class="jam-pop flex items-center justify-between gap-6 rounded-2xl bg-jam-pink px-8 py-4 text-white transition-colors duration-300 has-[[data-urgent]]:bg-jam-orange has-[[data-urgent]]:text-jam-ink"
      >
        <div class="flex items-center gap-5">
          <span class="jam-badge text-6xl !bg-none !bg-white !text-jam-pink" aria-hidden="true">
            <.icon name="hero-device-phone-mobile" class="size-[0.5em]" />
          </span>
          <div>
            <p class="whitespace-nowrap font-display text-5xl">Vote now</p>
            <p class="mt-2 whitespace-nowrap text-3xl text-white/85">On your own screen.</p>
          </div>
        </div>
        <.tv_timer
          :if={@view.round.deadline_ms}
          id="vote-countdown"
          label="Time left"
          deadline={@view.round.deadline_ms}
          class="[&_.jam-eyebrow]:text-white/80"
        />
      </div>
      <%!-- No clock yet: say what starts it, under the panel, so the panel
           (and "Vote now") keeps one shape whether or not a clock runs. --%>
      <p
        :if={!@all_in? and !@view.round.deadline_ms}
        id="clock-note"
        class="jam-pop text-3xl text-jam-cream/75"
      >
        The clock starts once most of you are in.
      </p>

      <%!-- The last few still choosing, by name: who the room is waiting
           on, said outright (the chips below are the whole roll). --%>
      <p
        :if={!@all_in? and @waiting != [] and length(@waiting) <= 3}
        id="waiting-for"
        class="text-3xl font-bold text-jam-cream"
      >
        {if @view.config[:name_non_voters?] == false,
          do: "Waiting for #{length(@waiting)} more",
          else: "Waiting for #{join_names(@waiting)}"}
      </p>

      <%!-- Who is in, by name: the room can see who it is waiting on. The
           picker is one of the names (their own guess counts as being in),
           so the list says nothing about whose song this is. Never what
           anyone chose. --%>
      <ul
        id="vote-chips"
        class="jam-pop flex flex-wrap items-center gap-2.5"
        aria-label="Who has locked in"
      >
        <%!-- The count first, so however many names wrap it is never the
             one pushed out of view. --%>
        <li id="vote-progress" class="pr-2 text-4xl text-jam-cream/75">
          <span class="font-display text-jam-cream">{@received} of {@expected}</span> in
        </li>
        <li
          :for={player <- @view.players}
          id={"chip-#{player.id}"}
          class={[
            "rounded-full px-5 py-1.5 text-3xl font-bold leading-tight transition-colors duration-300",
            if(player.id in @view.round.voters,
              do: "bg-jam-cream text-jam-ink",
              else: "bg-jam-cream/10 text-jam-cream/60"
            )
          ]}
        >
          {player.name}
        </li>
        <li :if={@view.audience != []} class="pl-3 jam-eyebrow">Audience</li>
        <li
          :for={member <- @view.audience}
          id={"chip-#{member.id}"}
          class={[
            "rounded-full px-4 py-1 text-2xl font-bold leading-tight transition-colors duration-300",
            if(member.id in @view.round.voters,
              do: "bg-jam-cream text-jam-ink",
              else: "bg-jam-cream/10 text-jam-cream/60"
            )
          ]}
        >
          {member.name}
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :deadline, :integer, required: true
  attr :class, :any, default: nil

  # A countdown that always says what it is counting down to.
  defp tv_timer(assigns) do
    ~H"""
    <div class={["shrink-0 space-y-1 text-right", @class]}>
      <p class="jam-eyebrow">{@label}</p>
      <p
        id={@id}
        phx-hook="Countdown"
        data-deadline={@deadline}
        class="font-display text-6xl leading-none tabular-nums"
      >
      </p>
    </div>
    """
  end

  # The reveal lands in three beats after a held breath (see `.jam-beat-*` in
  # app.css): the answer, what the room said, then what it was worth. No score
  # moves before the answer is on screen (see score_strip/1).
  defp results(%{view: %{round: %{style: :guess_question}}} = assigns) do
    assigns =
      assign(assigns,
        submitter_name: name_of(assigns.view, assigns.view.round.submitter_id),
        breakdown: vote_breakdown(assigns.view),
        forecast_line: forecast_line(assigns.view)
      )

    ~H"""
    <div id="tv-results" class="space-y-8">
      <div class="space-y-3">
        <p class="jam-rise font-display text-4xl text-jam-cream/70">The prompt was…</p>
        <p class="jam-pop jam-beat-1 origin-left font-display text-5xl leading-tight text-jam-pink">
          {@view.round.correct_prompt}
        </p>
        <p class="jam-rise jam-beat-1 text-3xl text-jam-cream/75">
          picked by <span class="font-bold text-jam-cream">{@submitter_name}</span>
        </p>
        <.forecast :if={@forecast_line} line={@forecast_line} class="jam-rise jam-beat-2" />
      </div>

      <div class="jam-rise jam-beat-2 space-y-6">
        <div :if={@breakdown.right != []} id="called-it" class="space-y-3">
          <p class="jam-eyebrow !text-jam-mint">Called it · +1 each</p>
          <div class="flex flex-wrap gap-2.5">
            <span :for={name <- @breakdown.right} class="jam-chip text-3xl">{name}</span>
          </div>
        </div>

        <div :if={@breakdown.wrong != []} id="fooled" class="space-y-3">
          <p class="jam-eyebrow !text-jam-orange">
            Fooled<span :if={@breakdown.fool_points > 0}> · +{@breakdown.fool_points} to {@submitter_name}</span>
          </p>
          <div class="flex flex-wrap gap-2.5">
            <span :for={name <- @breakdown.wrong} class="jam-chip text-3xl">{name}</span>
          </div>
        </div>

        <div :if={@breakdown.missing != []} id="no-vote" class="space-y-3">
          <p class="jam-eyebrow">{length(@breakdown.missing)} didn't vote</p>
          <div :if={@view.config[:name_non_voters?] != false} class="flex flex-wrap gap-2.5">
            <span :for={name <- @breakdown.missing} class="jam-chip text-3xl opacity-70">
              {name}
            </span>
          </div>
        </div>

        <p
          :if={@breakdown.right == [] and @breakdown.wrong == [] and @breakdown.audience_missed == 0}
          class="text-3xl text-jam-cream/60"
        >
          Nobody voted on this one.
        </p>
      </div>
    </div>
    """
  end

  defp results(assigns) do
    assigns =
      assign(assigns,
        submitter_name: name_of(assigns.view, assigns.view.round.submitter_id),
        guesses: guesses(assigns.view),
        breakdown: vote_breakdown(assigns.view),
        forecast_line: forecast_line(assigns.view),
        summary: reveal_summary(vote_breakdown(assigns.view))
      )

    assigns = assign(assigns, :guess_size, guess_size(length(assigns.guesses)))

    ~H"""
    <%!-- One stack, the same every round, built top-down in three beats:
         the name alone; then what it was worth to the picker, each line led
         by its points; then who said whom, with the points landing in the
         strip (`.jam-beat-1`, `-2`, `-2c` in app.css). --%>
    <div id="tv-results" class="space-y-4">
      <div>
        <p class="jam-rise font-display text-4xl text-jam-cream/80">
          {if timed_out?(@view.round), do: "Time's up. It was…", else: "It was…"}
        </p>
        <p class={[
          "jam-pop jam-beat-1 origin-left whitespace-nowrap font-display leading-none text-jam-pink",
          reveal_name_size(@submitter_name)
        ]}>
          {@submitter_name}
        </p>
      </div>

      <div class="jam-rise jam-beat-2 min-h-[6rem] space-y-1">
        <p id="reveal-summary" class="flex items-baseline gap-4 font-display text-5xl leading-tight">
          <span :if={@summary.points} class="text-jam-orange">{@summary.points}</span>
          <span class="text-jam-cream">{@summary.text}</span>
        </p>
        <%!-- The picker's prediction, right or not, in the same form. --%>
        <.forecast :if={@forecast_line} line={@forecast_line} />
      </div>

      <div class="jam-rise jam-beat-2c">
        <%!-- One card per player who was named, with who named them. --%>
        <ul
          :if={@guesses != []}
          id="room-said"
          class={["grid gap-3", guess_cols_class(length(@guesses))]}
        >
          <li
            :for={guess <- @guesses}
            id={"said-#{guess.id}"}
            class={[
              "jam-hand min-w-0",
              @guess_size.card,
              cond do
                guess.right? -> "bg-jam-mint text-jam-ink"
                guess.none? -> "border-2 border-dashed border-jam-cream/25 text-jam-cream/75"
                true -> "bg-jam-cream/10"
              end
            ]}
          >
            <%!-- The accusation is the headline; who made it reads under it. --%>
            <p class={["flex items-center gap-3 font-display leading-tight", @guess_size.said]}>
              <.icon
                :if={guess.right?}
                name="hero-check-circle-solid"
                class="size-[0.9em] shrink-0"
              />
              <span class="min-w-0 break-words">{card_heading(guess)}</span>
            </p>
            <p
              :if={guess.voters != []}
              class={["mt-1 line-clamp-2 font-bold leading-tight opacity-90", @guess_size.voters]}
            >
              {Enum.join(guess.voters, ", ")}
            </p>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # The running scores. Players only: the audience has its own board at the end.
  #
  # Everyone keeps one seat all game (the order they joined in), so a name is
  # always where the room last saw it; what changes is what the seat says: its
  # score, its place ("2nd") and whether it leads. Nothing ever moves, so there
  # is nothing to follow across the screen and no order to fall out of date.
  #
  # At a reveal the server has already added the round's points, but a seat
  # that changed first would give the answer away: each one shows what it said
  # before the round until the reveal's second beat, when what it says now
  # (new score, new place, the lead if it changed hands) lands over it, whole;
  # the old stays underneath until then, so a seat is never empty.
  defp score_strip(assigns) do
    view = assigns.view
    reveal? = view.round_state == :results
    deltas = (reveal? && view.round.deltas) || %{}
    before = Map.new(view.scores, fn {id, score} -> {id, score - Map.get(deltas, id, 0)} end)

    final_reveal? = suspense_reveal?(view, reveal?)
    was = seats_before(view, before, reveal?, final_reveal?)
    now = if final_reveal?, do: round_only(view.players), else: seats(view, view.scores)

    assigns =
      assign(assigns,
        submitter_id: reveal? && view.round.submitter_id,
        final_reveal?: final_reveal?,
        name_class: strip_name_class(view, final_reveal?),
        cells:
          for p <- view.players do
            %{
              id: p.id,
              name: p.name,
              now: now[p.id],
              was: was[p.id],
              gain: deltas[p.id] || 0,
              away?: not p.connected?
            }
          end
      )

    ~H"""
    <ol
      id="score-strip"
      aria-label="Scores"
      class={[
        "jam-panel relative flex h-28 shrink-0 justify-center gap-2 p-2",
        @final_reveal? && "pt-8"
      ]}
    >
      <%!-- The last reveal's strip says what the round was worth, not who
           leads: a label inside its own panel says so, and what comes next,
           arriving with the values it explains (and costing the reveal
           above no room). --%>
      <li
        :if={@final_reveal?}
        id="strip-label"
        class="jam-rise jam-beat-2c absolute left-5 top-2 jam-eyebrow !text-[1.35rem] !leading-none !text-jam-mint"
      >
        This round · final scores next
      </li>
      <li :for={cell <- @cells} id={"strip-#{cell.id}"} class="grid min-w-0 flex-1">
        <%= if cell.was != cell.now do %>
          <.seat
            id={"was-#{cell.id}-#{@view.round.index}"}
            name={cell.name}
            seat={cell.was}
            tag?={false}
            name_class={@name_class}
            away?={cell.away?}
            class="jam-out jam-beat-3"
            aria-hidden="true"
          />
          <.seat
            id={"now-#{cell.id}-#{@view.round.index}"}
            name={cell.name}
            seat={cell.now}
            name_class={@name_class}
            away?={cell.away?}
            gain={cell.gain}
            bluff?={cell.id == @submitter_id}
            class={["jam-beat-2c", if(cell.gain > 0, do: "jam-pop", else: "jam-rise")]}
          />
        <% else %>
          <.seat
            id={"now-#{cell.id}"}
            name={cell.name}
            seat={cell.now}
            name_class={@name_class}
            away?={cell.away?}
          />
        <% end %>
      </li>
    </ol>
    """
  end

  # One size for every name in the strip: smaller for all when one is long,
  # and on the last reveal, whose strip makes room for its label.
  defp strip_name_class(_view, true = _final_reveal?), do: "text-3xl"

  # Every place shown takes a row of its own: the names a size down to make
  # it room.
  defp strip_name_class(%{config: %{show_places?: true}}, false), do: "text-2xl"

  defp strip_name_class(%{players: players}, false) do
    if length(players) > 5 and Enum.any?(players, &(String.length(&1.name) > 11)),
      do: "text-3xl",
      else: "text-[2.1rem]"
  end

  # What the seats said before this round's points: at a reveal, the scores
  # without them; the last reveal's strip is about the round, not the lead.
  defp seats_before(view, _before, false = _reveal?, _final?),
    do: seats(view, view.scores)

  defp seats_before(view, before, true, false), do: seats(view, before)

  defp seats_before(view, before, true, true),
    do: view |> seats(before) |> Map.new(fn {id, seat} -> {id, %{seat | ring?: false}} end)

  # The game's last reveal, when the host keeps the totals back for the final
  # scores (their choice; the default).
  defp suspense_reveal?(view, reveal?),
    do: reveal? and final_round?(view) and view.config[:final_suspense?] != false

  # The last reveal of the game doesn't settle the table in the strip: the
  # seats say what each player won this round, and the totals (and who
  # leads) are the final board's to tell.
  defp round_only(players),
    do: Map.new(players, &{&1.id, %{score: nil, leader?: false, ring?: false}})

  # What each player's seat says for a set of scores: the score, and whether
  # they lead. By default places are the final board's to give (a strip of
  # "1st 1st 1st 2nd…" is noise from across a room) and only the lead is
  # marked, every tied leader alike; a host who wants every place on the
  # strip can have it (`show_places?`), once anyone has scored. The leader is
  # outlined, never filled, so the brightest thing in the strip is never a
  # name while the room is guessing one; a lead shared by half the room isn't
  # one worth pointing at.
  defp seats(view, scores) do
    board = Standings.rank(view.players, scores)
    top = for row <- board, row.rank == 1 and row.score > 0, do: row.id
    leaders = if length(top) * 2 < length(board), do: top, else: []
    places? = view.config[:show_places?] == true and Enum.any?(board, &(&1.score > 0))

    Map.new(board, fn row ->
      {row.id,
       %{score: row.score, rank: places? && row.rank, leader?: false, ring?: row.id in leaders}}
    end)
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :seat, :map, required: true
  attr :gain, :integer, default: 0
  attr :bluff?, :boolean, default: false
  attr :name_class, :string, default: "text-[2.1rem]"
  attr :away?, :boolean, default: false
  attr :tag?, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global

  # One seat in the score strip. The score sits under its own name, so no
  # number can be read as the next player's; the place is in the corner and
  # the round's points hang off the score, so neither moves it off centre.
  defp seat(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "relative flex h-full min-w-0 flex-col items-center justify-center gap-1.5 rounded-2xl px-2 [grid-area:1/1]",
        cond do
          @seat.leader? -> "bg-jam-cream text-jam-ink"
          @seat.ring? -> "bg-jam-night ring-4 ring-inset ring-jam-cream/80"
          true -> "bg-jam-night"
        end,
        @class
      ]}
      {@rest}
    >
      <%!-- The outline says who leads, in so many words; a phone that has
           dropped out says so in the same place, so the room can see who to
           help back in. Above the seat, never beside the name. --%>
      <span
        :if={@seat.ring? and @tag? and !@away?}
        class="absolute -top-6 left-1/2 -translate-x-1/2 rounded bg-jam-cream px-2.5 py-1 text-lg font-bold uppercase leading-none tracking-wider text-jam-ink"
      >
        Leads
      </span>
      <span
        :if={@away?}
        class="absolute -top-6 left-1/2 -translate-x-1/2 rounded bg-jam-orange px-2.5 py-1 text-lg font-bold uppercase leading-none tracking-wider text-jam-ink"
      >
        Away
      </span>
      <%!-- The place (when the host shows every place) has a row of its own
           above the name, so it never takes the name's room. --%>
      <span
        :if={@seat[:rank] && !@away?}
        class={[
          "rounded-md px-1.5 py-0.5 text-lg font-bold leading-none tabular-nums",
          if(@seat.rank == 1,
            do: "bg-jam-orange text-jam-ink",
            else: "bg-jam-cream/15 text-jam-cream/90"
          )
        ]}
      >
        {Standings.ordinal(@seat.rank)}
      </span>
      <%!-- All names in the strip share one size. --%>
      <span class={["flex max-w-full items-center gap-2 leading-none", @name_class]}>
        <span class={["truncate font-bold", @away? && "opacity-50"]}>{@name}</span>
      </span>
      <%!-- A seat with no total (the last reveal) says only what it won. --%>
      <span
        :if={is_nil(@seat.score)}
        class={[
          "font-display text-4xl leading-none tabular-nums",
          cond do
            @gain == 0 -> "text-jam-cream/30"
            @bluff? -> "text-jam-orange"
            true -> "text-jam-mint"
          end
        ]}
      >
        {if @gain > 0, do: "+#{@gain}", else: "–"}
      </span>
      <%!-- Place, score and what this round added, as one group under the
           name, so at any width each part sits with the score it belongs to
           (and "7" and "+7" never read as one number). --%>
      <span
        :if={@seat.score}
        class={["flex items-center justify-center gap-2.5", @away? && "opacity-50"]}
      >
        <span class={
          [
            "font-display leading-none tabular-nums",
            if(@seat[:rank], do: "text-4xl", else: "text-5xl"),
            cond do
              @seat.leader? -> "text-jam-ink"
              # Eight noughts before anybody has scored are not news.
              @seat.score == 0 -> "text-jam-cream/60"
              true -> "text-jam-orange"
            end
          ]
        }>
          {@seat.score}
        </span>
        <span
          :if={@gain > 0}
          class={
            [
              "rounded-full px-3 py-0.5 font-display text-3xl leading-none text-jam-ink",
              # The colours the lobby taught: mint for right guesses, orange for
              # the picker's bluff.
              if(@bluff?, do: "bg-jam-orange", else: "bg-jam-mint")
            ]
          }
        >
          +{@gain}
        </span>
      </span>
    </div>
    """
  end

  # ---- finished -----------------------------------------------------------

  defp finished(assigns) do
    audience = Standings.rank(assigns.view.audience, assigns.view.scores)
    {playlist, playlist_more} = playlist(assigns.view)

    winners = winner_rows(assigns.board)

    assigns =
      assign(assigns,
        audience_board: audience,
        winners: winners,
        # Somebody came out on top (not everyone on the same score), so first
        # place is worth holding back for a moment.
        crowned?: winners != [] and length(winners) < length(assigns.board),
        build?: not assigns.finale_seen?,
        awards: award_lines(assigns.view),
        playlist: playlist,
        playlist_more: playlist_more,
        winner_songs: winner_songs(assigns.view),
        count_steps: count_steps(assigns.board)
      )

    ~H"""
    <%!-- The ending is one screen: the winner and what the game is
         remembered for on the left, the whole table on the right, read top to
         bottom. The table fills from the bottom (everyone below third at once,
         then third, then second, then a held breath), and the winner arrives
         last, in first place and in the headline at once
         (`.jam-count-*` and `.jam-finale-*` in app.css); no row stands empty
         waiting for them. The host's buttons follow. Phones wait for the
         winner (`.jam-until-winner`).

         The winner's moment is the one the whole room watches, so it has
         a beat of its own: the name alone, filling the screen, held for a
         couple of seconds (`.jam-winner-card`), before the table it tops
         comes back. --%>
    <div
      :if={@build? and @winners != []}
      id="winner-card"
      class="jam-winner-card fixed inset-0 z-30 grid place-items-center bg-jam-ink px-16 text-center"
      aria-hidden="true"
    >
      <div class={[
        "flex items-center",
        if(length(@winner_songs) == 1,
          do: "gap-14 text-left",
          else: "flex-col gap-10 text-center"
        )
      ]}>
        <%!-- The winner's song beside their name (each winner's, above their
             names, in a tie): their best bluff, when the night's best was
             theirs, and it says so. --%>
        <div :if={@winner_songs != []} class="flex shrink-0 items-start gap-8">
          <div :for={song <- @winner_songs} class="flex flex-col items-center gap-4">
            <.poster song={song} heading?={false} />
            <%!-- Tied winners' songs each say whose they are. --%>
            <p
              :if={length(@winner_songs) > 1}
              class="max-w-64 truncate text-center font-display text-4xl text-jam-orange"
            >
              {song.owner}
            </p>
            <p :if={song.caption} class="max-w-64 text-center text-2xl font-bold text-jam-cream/85">
              {song.caption}
            </p>
          </div>
        </div>
        <.jam_badge :if={@winner_songs == []} icon="hero-trophy" class="text-9xl" />
        <div class="min-w-0 space-y-6">
          <p class={[
            "jam-pop jam-finale-win font-display leading-none text-balance text-jam-orange",
            winner_card_size(@winners, @board)
          ]}>
            <.winner_names winners={@winners} board={@board} />
          </p>
          <p class="text-4xl font-bold text-jam-cream/80">
            {winner_points(@winners)}<span :if={winner_margin(@winners, @board)}> · {winner_margin(
              @winners,
              @board
            )}</span>
          </p>
        </div>
      </div>
    </div>
    <div class="min-h-screen flex flex-col justify-center gap-7 px-12 lg:px-20 pt-24 pb-16">
      <div class="grid gap-x-16 gap-y-8 lg:grid-cols-2 lg:items-center">
        <%!-- One left edge for the heading and the awards under it. --%>
        <div class="space-y-10">
          <div>
            <div class="min-w-0 space-y-2">
              <%!-- The tie is news the winner's moment breaks, not the
                   countdown before it. --%>
              <p class="jam-eyebrow">
                Final scores<span
                  :if={length(@winners) > 1 and length(@winners) < length(@board)}
                  class={@build? && "jam-rise jam-finale-win"}
                > · It's a tie</span>
              </p>
              <div class="grid items-center">
                <%!-- What holds the winner's place until they are named. --%>
                <p
                  :if={@build?}
                  id="winner-wait"
                  class="jam-out jam-finale-wait font-display text-6xl leading-tight text-jam-cream [grid-area:1/1]"
                  aria-hidden="true"
                >
                  And the winner is…
                </p>
                <h1
                  id="winner"
                  class={[
                    "font-display leading-none text-balance text-jam-orange [grid-area:1/1]",
                    winner_size_class(length(@winners)),
                    @build? && "jam-pop jam-finale-win origin-left"
                  ]}
                >
                  <.winner_names winners={@winners} board={@board} />
                </h1>
              </div>
              <%!-- How it was won: the score, and how close it was. --%>
              <p
                :if={@winners != []}
                id="winner-margin"
                class={["text-3xl text-jam-cream/75", @build? && "jam-rise jam-finale-after-1"]}
              >
                <span class="block">{winner_points(@winners)}</span>
                <span
                  :if={winner_margin(@winners, @board)}
                  class="block whitespace-nowrap font-bold text-jam-cream"
                >
                  {winner_margin(@winners, @board)}
                </span>
              </p>
            </div>
          </div>

          <%!-- What the game is remembered for, beyond the scores. --%>
          <dl
            :if={@awards != []}
            id="awards"
            class={["space-y-5", @build? && "jam-rise jam-finale-after-2"]}
          >
            <div :for={{title, line} <- @awards}>
              <dt class="jam-eyebrow !text-jam-pink">{title}</dt>
              <dd class="mt-1 text-4xl font-bold leading-tight text-balance">{line}</dd>
            </div>
          </dl>
        </div>

        <div class="space-y-6">
          <%!-- One column, best first, the way every phone lists it too. --%>
          <ol :if={!@playlist_open?} id="final-scores" class="space-y-2">
            <li
              :for={row <- @board}
              class={
                [
                  "flex items-center justify-between gap-6 rounded-2xl px-6",
                  # Eight rows still leave room for the buttons under them.
                  if(length(@board) > 6,
                    do: "py-2 text-[1.95rem] leading-tight",
                    else: "py-3 text-[2.15rem]"
                  ),
                  if(@crowned? and row.rank == 1,
                    do: "bg-jam-orange font-bold text-jam-ink",
                    else: "jam-panel"
                  ),
                  @build? && @crowned? && row.rank == 1 && "jam-pop jam-finale-win",
                  @build? && !(@crowned? and row.rank == 1) &&
                    "jam-rise #{count_class(row.rank, @count_steps)}"
                ]
              }
            >
              <span class="flex min-w-0 items-baseline gap-4">
                <span class={[
                  "w-20 shrink-0 text-[1.6rem] font-bold tabular-nums",
                  row.rank != 1 && "opacity-70"
                ]}>
                  {Standings.ordinal(row.rank)}
                </span>
                <span class="truncate font-display">{row.name}</span>
              </span>
              <span class="font-display tabular-nums">{row.score}</span>
            </li>
          </ol>

          <%!-- What the room takes home, on the host's say-so: the night's songs,
               and whose they were. --%>
          <div :if={@playlist_open?} id="playlist" class="jam-rise space-y-4">
            <p class="jam-eyebrow">Tonight's playlist</p>
            <ol class="space-y-3 text-3xl">
              <li :for={song <- @playlist} class="flex items-baseline justify-between gap-8">
                <span class="min-w-0 truncate">
                  <span class="font-display">{song.song_name}</span>
                  <span :if={song.artist} class="text-2xl text-jam-cream/60">· {song.artist}</span>
                </span>
                <span class="shrink-0 font-bold text-jam-cream/60">{song.picked_by}</span>
              </li>
            </ol>
            <p :if={@playlist_more > 0} class="text-2xl text-jam-cream/50">
              and {@playlist_more} more
            </p>
          </div>

          <%!-- The audience's own table, under the players', a row each. --%>
          <div
            :if={@audience_board != []}
            id="audience-scores"
            class={["space-y-2", @build? && "jam-rise jam-finale-after-2"]}
          >
            <p class="jam-eyebrow">Audience · correct guesses</p>
            <p
              :for={row <- @audience_board}
              class="flex items-center justify-between gap-6 rounded-2xl bg-jam-cream/5 px-6 py-2 text-2xl"
            >
              <span class="truncate font-display">{row.name}</span>
              <span class="font-bold text-jam-cream/80">{row.score} correct</span>
            </p>
          </div>
        </div>
      </div>

      <div class={["flex flex-wrap items-center gap-4", @build? && "jam-rise jam-finale-after-3"]}>
        <button phx-click="play_again" class="jam-btn text-3xl">Play again</button>
        <button
          :if={@playlist != []}
          id="toggle-playlist"
          type="button"
          phx-click="toggle_playlist"
          class="jam-btn jam-btn-ghost text-3xl transition-colors hover:bg-jam-cream/15"
        >
          <.icon name="hero-queue-list" class="size-6" />
          {if @playlist_open?, do: "Back to the scores", else: "Tonight's playlist"}
        </button>
        <button
          id="exit-game"
          type="button"
          phx-click="exit_game"
          data-confirm="End the game for everyone?"
          class="jam-btn jam-btn-ghost text-3xl transition-colors hover:bg-jam-cream/15"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-6" /> Exit game
        </button>
        <p class="text-2xl text-jam-cream/65">Play again keeps everyone in and deals new prompts.</p>
      </div>
    </div>
    """
  end

  # =========================================================================
  # View helpers
  # =========================================================================

  defp current_art(%{phase: :playing, round: %{song: %{album_art_url: url}}})
       when is_binary(url) and url != "",
       do: url

  # The finished game's colour comes from the winner's song, so the ending
  # isn't the one screen without any.
  defp current_art(%{phase: :finished} = view) do
    case winner_songs(view) do
      [%{album_art_url: url} | _] -> url
      _ -> nil
    end
  end

  defp current_art(_view), do: nil

  # Each winner's song, for the finale's posters (the first also tints the
  # screen): their best bluff when the night's best bluff was theirs (with a
  # caption saying so), else their first song with a cover. None when
  # everyone tied (nobody won) or more than three share the top.
  defp winner_songs(%{phase: :finished, playlist: [_ | _] = songs} = view) do
    board = Standings.rank(view.players, view.scores)

    case winner_rows(board) do
      winners when length(winners) < length(board) and length(winners) <= 3 ->
        Enum.flat_map(winners, &List.wrap(winner_song(songs, &1, view)))

      _none ->
        []
    end
  end

  defp winner_songs(_view), do: []

  # Each song says whose it is, so tied winners' posters can't be mixed up.
  defp winner_song(songs, winner, view) do
    case Enum.filter(songs, &covered_song?(&1, winner.id)) do
      [] ->
        nil

      [first | _] = covered ->
        song =
          bluff_song(covered, best_bluff_of(view, winner.id)) || Map.put(first, :caption, nil)

        Map.put(song, :owner, winner.name)
    end
  end

  defp bluff_song(_covered, nil), do: nil

  defp bluff_song(covered, {song_name, fooled}) do
    case Enum.find(covered, &(&1.song_name == song_name)) do
      nil -> nil
      song -> Map.put(song, :caption, "Best bluff · fooled #{fooled}")
    end
  end

  defp covered_song?(song, player_id) do
    url = Map.get(song, :album_art_url)
    song.player_id == player_id and is_binary(url) and url != ""
  end

  # The night's best bluff, if it was this player's and fooled more than one.
  defp best_bluff_of(%{awards: %{best_bluff: %{fooled: fooled, bluffs: bluffs}}}, player_id)
       when fooled > 1 do
    case Enum.find(bluffs, &(&1.player_id == player_id)) do
      %{song_name: song_name} -> {song_name, fooled}
      nil -> nil
    end
  end

  defp best_bluff_of(_view, _player_id), do: nil

  defp runtime_estimate(view) do
    player_count = max(length(view.players), 1)
    config = Config.build(view.config, player_count)

    subround_count =
      view.theme.style_sequence |> Enum.uniq() |> length() |> max(1)

    seconds = Config.estimated_runtime_s(config, player_count, subround_count)
    max(1, round(seconds / 60))
  end

  defp progress_style(%{submitted: s, total: t}) when t > 0 do
    "width: #{round(s / t * 100)}%"
  end

  defp progress_style(_), do: "width: 0%"

  defp second_take?(%{prompt_take: %{nth: nth}}), do: nth > 1
  defp second_take?(_round), do: false

  defp take_label(%{nth: 1, of: of}), do: "#{of} people picked for this prompt"
  defp take_label(%{nth: 2, of: 2}), do: "The other pick for this prompt"
  defp take_label(%{nth: nth, of: of}), do: "Pick #{nth} of #{of} for this prompt"

  # The answer as large as it can be and still sit on one line: names run up
  # to 24 characters.
  defp reveal_name_size(name) do
    case String.length(name) do
      n when n <= 8 -> "text-[8rem]"
      n when n <= 12 -> "text-[6.5rem]"
      n when n <= 17 -> "text-[5rem]"
      _ -> "text-[3.75rem]"
    end
  end

  # The vote closed on the clock rather than with every vote in.
  defp timed_out?(%{all_in?: all_in?}), do: not all_in?
  defp timed_out?(_round), do: false

  # The last round of the whole game (its last sub-round's last round).
  defp final_round?(%{round: %{index: index, total: total}} = view),
    do: index + 1 == total and view.subround_index + 1 == view.subround_total

  defp final_round?(_view), do: false

  # A round's card holds long enough to read a prompt the room hasn't seen;
  # with nothing new to read (no prompt on it, or the one the last round had)
  # it is a quicker beat. The phones' card keeps the same time.
  defp quick_card?(%{index: 0}), do: false
  defp quick_card?(%{prompt: nil}), do: true
  defp quick_card?(%{prompt_take: %{back_to_back?: true}}), do: true
  defp quick_card?(_round), do: false

  # What a round asks, the same words from its first note to its last vote.
  defp round_question(:guess_question), do: "What was this picked for?"
  defp round_question(_style), do: "Whose jam is this?"

  defp name_of(view, id) do
    case Enum.find(view.players ++ view.audience, &(&1.id == id)) do
      nil -> "someone"
      p -> p.name
    end
  end

  # Who called it and who was fooled, in seat order, from the votes the reveal
  # carries. Only players can be fooled, as only they earn the picker points
  # (`Scoring.score_round/2`): an audience guess that missed is counted apart.
  defp vote_breakdown(%{round: round} = view) do
    choices = Map.new(round.votes || [], &{&1.voter_id, &1.choice})
    voters = Enum.filter(view.players ++ view.audience, &Map.has_key?(choices, &1.id))
    {right, missed} = Enum.split_with(voters, &(choices[&1.id] == round.correct_choice))
    {wrong, audience_missed} = Enum.split_with(missed, &(&1.role == :player))

    # Who could have voted (connected, and not the picker) and didn't.
    missing =
      for p <- view.players ++ view.audience,
          p.connected?,
          p.id != round.submitter_id,
          not Map.has_key?(choices, p.id),
          do: p.name

    %{
      right: Enum.map(right, & &1.name),
      wrong: Enum.map(wrong, & &1.name),
      audience_missed: length(audience_missed),
      players_voted: Enum.count(voters, &(&1.role == :player)),
      missing: missing,
      # What fooling the room was worth: the picker's points, less the one
      # for a guess that came true (which gets a line of its own).
      fool_points: Map.get(round.deltas || %{}, round.submitter_id, 0) - forecast_point(round)
    }
  end

  defp forecast_point(%{forecast: %{right?: true}}), do: 1
  defp forecast_point(_round), do: 0

  # The picker's prediction (which wrong answer the room would fall for), and
  # whether it came true: `{text, right?}`, or nil when they made none or
  # nobody was fooled (so nobody took the blame). One sentence, the same words
  # as the picker's phone, whichever way it went.
  defp forecast_line(%{round: %{forecast: %{choice: choice, right?: right?}} = round} = view) do
    case blamed(view, round) do
      # Nobody was fooled, so nobody took any blame: the prediction says so.
      [] ->
        {"Guessed #{choice_name(view, round, choice)} · nobody was fooled", false}

      took ->
        {prediction(choice_name(view, round, choice), took, right?, round.style), right?}
    end
  end

  defp forecast_line(_view), do: nil

  # One word for the mechanic everywhere, blame: whoever most of the wrong
  # guesses went to "took the blame" (true however few were fooled; never
  # "the room"), and whether the picker called it. A miss is said as clearly
  # as a hit, with no points to it.
  defp prediction(_guess, took, true, _style),
    do: "Called the blame: #{join_names(took)}"

  defp prediction(guess, took, false, _style),
    do: "Guessed #{guess} · #{join_names(took)} took the blame"

  attr :line, :any, required: true
  attr :class, :any, default: nil

  # The prediction's line on the reveal, led by what it was worth (+1 or +0)
  # like the picker's own line above it.
  defp forecast(assigns) do
    ~H"""
    <p
      id="forecast"
      class={[
        "flex items-baseline gap-4 font-display text-4xl leading-tight",
        if(elem(@line, 1), do: "text-jam-cream", else: "text-jam-cream/85"),
        @class
      ]}
    >
      <span :if={elem(@line, 1)} class="font-display text-jam-orange">+1</span>
      <span>{elem(@line, 0)}</span>
    </p>
    """
  end

  # Whom (or which prompt) the fooled players named most, as words.
  defp blamed(view, round) do
    wrong =
      for vote <- round.votes || [],
          vote.voter_role == :player and vote.choice != round.correct_choice,
          do: vote.choice

    case Enum.frequencies(wrong) do
      counts when counts == %{} ->
        []

      counts ->
        top = counts |> Map.values() |> Enum.max()

        counts
        |> Enum.filter(fn {_choice, n} -> n == top end)
        |> Enum.map(fn {choice, _n} -> choice_name(view, round, choice) end)
        |> Enum.sort()
    end
  end

  defp choice_name(view, %{style: :guess_who}, choice), do: name_of(view, choice)

  defp choice_name(_view, %{choices: choices}, choice) do
    case Enum.find(choices, &(&1.id == choice)) do
      %{prompt: prompt} -> "\u201c#{prompt}\u201d"
      _ -> "another prompt"
    end
  end

  # A guess card's heading: the right one says what it means (the answer is
  # on screen above it), the others whom they named.
  defp card_heading(%{right?: true, voters: voters}), do: "#{length(voters)} called it"
  defp card_heading(%{none?: true, count: count}), do: "#{count} didn't vote"
  defp card_heading(guess), do: "#{length(guess.voters)} said #{guess.name}"

  # Columns for the reveal's guess cards, so any number of them fits.
  defp guess_cols_class(1), do: "grid-cols-1"
  defp guess_cols_class(count) when count in [2, 4], do: "grid-cols-2"
  defp guess_cols_class(count) when count in [3, 5, 6], do: "grid-cols-3"
  defp guess_cols_class(_count), do: "grid-cols-4"

  # How large the room's guesses are set: as large as the number of cards
  # leaves room for. A room that agreed (one to three suspects, one row) gets
  # them at a size to read from the sofa; a room that scattered needs two rows,
  # so each card is smaller and the reveal still fits above the scores.
  defp guess_size(count) when count <= 2,
    do: %{card: "rounded-3xl px-6 py-4", said: "text-[2.75rem]", voters: "text-4xl"}

  defp guess_size(3),
    do: %{card: "rounded-3xl px-6 py-4", said: "text-[2.4rem]", voters: "text-[2.2rem]"}

  defp guess_size(_count),
    do: %{card: "rounded-2xl px-5 py-3", said: "text-[2.1rem]", voters: "text-[1.7rem]"}

  # A guess-who round's votes by suspect: each player somebody named, with who
  # named them. The right answer always comes first, so the eye knows where to
  # find it; then the most-named (in seat order between equals).
  defp guesses(%{round: round} = view) do
    choices = Map.new(round.votes || [], &{&1.voter_id, &1.choice})
    voters = Enum.filter(view.players ++ view.audience, &Map.has_key?(choices, &1.id))

    named =
      for suspect <- view.players,
          named_by = for(v <- voters, choices[v.id] == suspect.id, do: v.name),
          named_by != [] do
        %{
          id: suspect.id,
          name: suspect.name,
          voters: named_by,
          right?: suspect.id == round.correct_choice,
          none?: false
        }
      end

    # Who let the clock run out gets a card too, last and dimmed: the room
    # can see who sat it out (by name, unless the host would rather it only
    # counted them).
    none =
      case vote_breakdown(view).missing do
        [] ->
          []

        names ->
          [
            %{
              id: "none",
              name: nil,
              count: length(names),
              voters: if(view.config[:name_non_voters?] == false, do: [], else: names),
              right?: false,
              none?: true
            }
          ]
      end

    Enum.sort_by(named, &{not &1.right?, -length(&1.voters)}) ++ none
  end

  # What the picker made of the round: always the first line, because fooling
  # the room is what the game pays for. Up to three fooled players are named.
  # What the picker made of the room, led by its points.
  defp reveal_summary(%{right: [], wrong: [], audience_missed: 0}),
    do: %{points: nil, text: "Nobody voted."}

  # Not "nobody" when the audience fell for it, though that scores nothing.
  defp reveal_summary(%{wrong: [], audience_missed: n}) when n > 0,
    do: %{points: nil, text: "No player fell for it."}

  # Not "everyone" when somebody didn't vote.
  defp reveal_summary(%{wrong: [], missing: [_ | _]}),
    do: %{points: nil, text: "Nobody fell for it."}

  defp reveal_summary(%{wrong: []}), do: %{points: nil, text: "Everyone saw through it."}

  defp reveal_summary(%{wrong: wrong, fool_points: points}) when length(wrong) <= 3,
    do: %{points: plus_points(points), text: "Fooled #{join_names(wrong)}"}

  defp reveal_summary(%{wrong: wrong, players_voted: voted, fool_points: points}),
    do: %{points: plus_points(points), text: "Fooled #{length(wrong)} of #{voted}"}

  defp plus_points(0), do: nil
  defp plus_points(points), do: "+#{points}"

  # The night's songs with who picked each: as many as fit beside the final
  # board, and how many more there were.
  defp playlist(%{playlist: songs} = view) when is_list(songs) do
    {shown, rest} = Enum.split(songs, @playlist_shown)

    {for(
       song <- shown,
       do: %{
         song_name: song.song_name,
         artist: Map.get(song, :artist),
         picked_by: name_of(view, song.player_id)
       }
     ), length(rest)}
  end

  defp playlist(_view), do: {[], 0}

  # The finished game's awards as {title, sentence} lines.
  defp award_lines(%{awards: awards} = view) when is_map(awards) do
    case {bluff_line(view, awards.best_bluff), sharpest_line(view, awards.sharpest)} do
      # Both to the one winner: one line, not the same name three times.
      {{_, _}, {_, _}} = both ->
        merged_awards(view, awards, both)

      {bluff, sharpest} ->
        Enum.reject([bluff, sharpest], &is_nil/1)
    end
  end

  defp award_lines(_view), do: []

  defp merged_awards(view, awards, {bluff, sharpest}) do
    winners = view.players |> Standings.rank(view.scores) |> winner_rows()

    case {winners, awards.best_bluff.bluffs, awards.sharpest.player_ids} do
      {[%{id: id}], [%{player_id: id, song_name: song}], [id]} ->
        [
          {"Best bluff & sharpest ears",
           "Fooled #{awards.best_bluff.fooled} with #{song}, and guessed #{awards.sharpest.called} right"}
        ]

      _otherwise ->
        [bluff, sharpest]
    end
  end

  defp bluff_line(_view, nil), do: nil
  # Fooling one player is no feat to hand out.
  defp bluff_line(_view, %{fooled: fooled}) when fooled <= 1, do: nil

  # Tied bluffs can be one player's songs, or several players'. An award more
  # than two players share singles nobody out, so it isn't given.
  defp bluff_line(view, %{fooled: fooled, bluffs: bluffs}) do
    case Enum.uniq_by(bluffs, & &1.player_id) do
      [%{player_id: id}] ->
        {"Best bluff", "#{name_of(view, id)} fooled #{fooled} with #{bluff_songs(bluffs)}"}

      [_, _] = holders ->
        names = holders |> Enum.map(&name_of(view, &1.player_id)) |> join_names()
        {"Best bluff", "#{names} each fooled #{fooled}"}

      _shared ->
        nil
    end
  end

  defp bluff_songs([%{song_name: song}]), do: song
  defp bluff_songs(songs), do: "each of #{length(songs)} songs"

  defp sharpest_line(_view, nil), do: nil
  defp sharpest_line(_view, %{called: called}) when called <= 1, do: nil

  defp sharpest_line(view, %{called: called, player_ids: [id]}),
    do: {"Sharpest ears", "#{name_of(view, id)} guessed #{called} right"}

  defp sharpest_line(view, %{called: called, player_ids: [_, _] = ids}) do
    names = ids |> Enum.map(&name_of(view, &1)) |> join_names()
    {"Sharpest ears", "#{names} each guessed #{called} right"}
  end

  defp sharpest_line(_view, _shared), do: nil

  defp winner_rows(board), do: Enum.filter(board, &(&1.rank == 1))

  defp winner_headline([], _board), do: "Game over"
  defp winner_headline([winner], _board), do: "#{winner.name} wins"

  defp winner_headline(winners, board)
       when length(winners) == length(board) and length(board) > 2,
       do: "Everyone tied"

  defp winner_headline(winners, _board),
    do: "#{join_names(Enum.map(winners, & &1.name))} share the win"

  attr :winners, :list, required: true
  attr :board, :list, required: true

  # The winner headline with each name kept whole: it breaks between names,
  # never inside one ("Maximiliana-Rose / & Cleo"). A tie says so above it.
  defp winner_names(%{winners: [_ | _] = winners, board: board} = assigns)
       when length(winners) < length(board) or length(board) <= 2 do
    assigns =
      assign(assigns,
        names: Enum.map(winners, & &1.name),
        verb: if(length(winners) == 1, do: "wins", else: "share the win")
      )

    ~H"""
    <%= for {name, index} <- Enum.with_index(@names) do %>
      <span :if={index > 0 and index == length(@names) - 1}>&</span>
      <span class="whitespace-nowrap">{name}{if index < length(@names) - 2, do: ","}</span>
    <% end %>
    {@verb}
    """
  end

  defp winner_names(assigns) do
    ~H"""
    {winner_headline(@winners, @board)}
    """
  end

  # When a row of the final table arrives: second and third each get a beat
  # of their own, everyone below them comes in together.
  defp count_class(2, _steps), do: "jam-count-second"
  defp count_class(3, _steps), do: "jam-count-third"
  defp count_class(rank, steps), do: "jam-count-step-#{Map.get(steps, rank, 0)}"

  # Each place below third, counted up from last place (equal places land
  # together), so the table fills one row at a time from the bottom.
  defp count_steps(board) do
    board
    |> Enum.map(& &1.rank)
    |> Enum.filter(&(&1 > 3))
    |> Enum.uniq()
    |> Enum.sort(:desc)
    |> Enum.with_index()
    |> Map.new(fn {rank, step} -> {rank, min(step, 5)} end)
  end

  # The winner's own beat: about twice a reveal's name, as large as the
  # headline's length leaves room for.
  defp winner_card_size(winners, board) do
    case String.length(winner_headline(winners, board)) do
      n when n <= 10 -> "text-[13rem]"
      n when n <= 16 -> "text-[9rem]"
      n when n <= 24 -> "text-[6.5rem]"
      _ -> "text-[5rem]"
    end
  end

  # One winner's name can be set large; names sharing the line need the room.
  defp winner_size_class(1), do: "text-8xl"
  defp winner_size_class(2), do: "text-7xl"
  defp winner_size_class(_count), do: "text-5xl"

  defp winner_points([%{score: 1}]), do: "with 1 point"
  defp winner_points([%{score: score}]), do: "with #{score} points"
  defp winner_points([%{score: 1} | _]), do: "on 1 point each"
  defp winner_points([%{score: score} | _]), do: "on #{score} points each"

  # How close it was, when one player won outright: the margin over whoever
  # came next. Nothing to say for a tie at the top, or a game of one.
  defp winner_margin([winner], board) do
    case Enum.filter(board, &(&1.rank == 2)) do
      [] ->
        nil

      [%{score: score} | _] = next ->
        "#{points(winner.score - score)} ahead of #{join_names(Enum.map(next, & &1.name))}"
    end
  end

  defp winner_margin(_winners, _board), do: nil

  defp points(1), do: "1 point"
  defp points(n), do: "#{n} points"

  defp join_names([name]), do: name
  defp join_names([a, b]), do: "#{a} & #{b}"

  defp join_names(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " & " <> last
  end
end
