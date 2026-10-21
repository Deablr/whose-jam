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
  lists the providers the host can connect (Spotify today), and everything else
  speaks in terms of "the music service". When no premium-ready service is
  connected the lobby prompts the host to connect one.

  ## Playback approach

  Playback is **attribute-driven**, not command-driven. The hook element carries
  two data attributes:

    * `data-token` — the host's current access token (refreshed server-side on a
      timer via `WhoseJam.Spotify.Auth.refresh/1` + `Game.set_spotify/2`).
    * `data-uri` — the Spotify track URI to be playing *right now*, or `""`.

  The LiveView sets `data-uri` to the current round's song only while the round
  is `:revealing`; the hook reconciles real playback toward it (transfer +
  `PUT /v1/me/player/play` with the device id). When the track finishes the hook
  pushes `"song_ended"`, which advances the round. Any token/SDK failure pushes
  `"playback_error"` and we show a visible banner — the server's reveal-safety
  timer advances the game regardless, so a dead player never wedges the game.
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.Game
  alias WhoseJam.Game.Config
  alias WhoseJam.Spotify.Auth

  @token_refresh_lead_s 60
  @token_refresh_floor_ms 30_000

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
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
        music_prompt_dismissed?: false,
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
    previous = spotify_of(socket.assigns.view)
    socket = assign(socket, view: Game.host_state(socket.assigns.code))

    socket =
      if spotify_of(socket.assigns.view) != previous, do: assign_playback(socket), else: socket

    {:noreply, socket}
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

  def handle_event("set_config", params, socket) do
    Game.set_config(socket.assigns.code, config_overrides(params))
    {:noreply, socket}
  end

  def handle_event("start", _params, socket) do
    case Game.start_game(socket.assigns.code) do
      :ok ->
        {:noreply, socket}

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
    {:noreply, socket}
  end

  def handle_event("song_ended", _params, socket) do
    Game.song_ended(socket.assigns.code)
    {:noreply, socket}
  end

  def handle_event("playback_ready", _params, socket) do
    {:noreply, assign(socket, playback_ready?: true, playback_error: nil)}
  end

  def handle_event("playback_error", params, socket) do
    {:noreply,
     assign(socket, playback_ready?: false, playback_error: playback_error_message(params))}
  end

  @host_settings ~w(answer_timer_s vote_delay_s vote_timer_s questions_per_player
                    subrounds_enabled? allow_vote_change? min_players)

  # Forward only the setting the host just changed. The form posts every field,
  # and untouched ones still hold player-count-derived defaults — sending them
  # would pin those defaults as overrides (e.g. an empty lobby's 15 questions
  # per player sticking after 8 people join).
  defp config_overrides(%{"_target" => [field | _]} = params) when field in @host_settings do
    Map.take(params, [field])
  end

  defp config_overrides(_params), do: %{}

  defp start_error(:not_enough_players), do: "Not enough players have joined yet."
  defp start_error(:not_authenticated), do: "Connect a music service first."
  defp start_error(:not_premium), do: "That Spotify account isn't Premium — playback won't work."
  defp start_error(:already_started), do: "The game has already started."
  defp start_error(_), do: "Couldn't start the game. Please try again."

  # =========================================================================
  # Playback token
  # =========================================================================

  defp assign_playback(socket) do
    if ref = socket.assigns.refresh_timer, do: Process.cancel_timer(ref)

    case usable_spotify(socket.assigns.view) do
      {:ok, spotify} ->
        {token, expires_at} = ensure_fresh_token(socket.assigns.code, spotify)

        assign(socket,
          spotify_token: token,
          spotify_status: :ok,
          refresh_timer: schedule_token_refresh(expires_at)
        )

      {:unavailable, reason} ->
        assign(socket,
          spotify_token: nil,
          spotify_status: {:unavailable, reason},
          playback_ready?: false,
          refresh_timer: nil
        )
    end
  end

  defp usable_spotify(%{spotify: spotify}) when is_map(spotify) do
    if Map.get(spotify, :premium?) == true do
      {:ok, spotify}
    else
      {:unavailable, "The connected Spotify account isn't Premium, so playback is disabled."}
    end
  end

  defp usable_spotify(_view), do: {:unavailable, "No music service is connected."}

  defp spotify_of(%{spotify: spotify}), do: spotify
  defp spotify_of(_view), do: nil

  # Returns {access_token, expires_at}, refreshing (and persisting) if the token
  # is within the refresh lead of expiring.
  defp ensure_fresh_token(code, spotify) do
    access_token = Map.get(spotify, :access_token)
    expires_at = Map.get(spotify, :expires_at)
    threshold = DateTime.add(DateTime.utc_now(), @token_refresh_lead_s, :second)

    if is_nil(expires_at) or DateTime.compare(expires_at, threshold) == :gt do
      {access_token, expires_at}
    else
      case Auth.refresh(Map.get(spotify, :refresh_token)) do
        {:ok, %{access_token: new_token, expires_at: new_expiry}} ->
          Game.set_spotify(code, %{spotify | access_token: new_token, expires_at: new_expiry})
          {new_token, new_expiry}

        _ ->
          {access_token, expires_at}
      end
    end
  end

  defp schedule_token_refresh(nil), do: nil

  defp schedule_token_refresh(%DateTime{} = expires_at) do
    secs = DateTime.diff(expires_at, DateTime.utc_now(), :second)
    ms = max(@token_refresh_floor_ms, (secs - @token_refresh_lead_s) * 1000)
    Process.send_after(self(), :refresh_token, ms)
  end

  defp qr_svg(url) do
    url
    |> EQRCode.encode()
    |> EQRCode.svg(width: 300, background_color: "#fbf1e1", color: "#120726")
  end

  # The URI that should be playing right now: the current round's song, which
  # keeps playing through voting and the reveal until the next round starts.
  defp play_uri(%{phase: :playing, round: %{song: %{uri: uri}}}) when is_binary(uri),
    do: uri

  defp play_uri(_view), do: ""

  defp playback_error_message(%{"reason" => "initialization_error"}),
    do:
      "This browser can't play protected Spotify audio (DRM/Widevine unavailable). " <>
        "Open this page in desktop Chrome, Edge, or Firefox — built-in app browsers " <>
        "(editor/IDE previews, Electron apps) don't include Widevine. Use https, or " <>
        "localhost on this machine; http on a LAN IP also disables DRM."

  defp playback_error_message(%{"reason" => "no_token"}),
    do: "No Spotify token — reconnect Spotify in Settings."

  defp playback_error_message(%{"reason" => "authentication_error"}),
    do: "Spotify rejected the token — reconnect Spotify in Settings."

  defp playback_error_message(%{"reason" => "account_error"}),
    do: "Spotify playback needs a Premium account."

  defp playback_error_message(_), do: "Spotify playback is unavailable right now."

  # Lobby: only real player failures (missing connection is handled by the
  # connect prompt). In game: anything that stops audio.
  defp playback_banner(assigns) do
    cond do
      assigns.view.phase == :finished -> nil
      assigns.playback_error -> assigns.playback_error
      assigns.view.phase == :lobby -> nil
      match?({:unavailable, _}, assigns.spotify_status) -> elem(assigns.spotify_status, 1)
      true -> nil
    end
  end

  # =========================================================================
  # Music services
  # =========================================================================

  # Every provider the host can connect. Spotify is the only one today; new
  # services slot in here with the same shape.
  defp music_services(view, code) do
    [
      %{
        id: :spotify,
        name: "Spotify",
        requirement: "Premium account required for full-song playback.",
        status: spotify_connection(view.spotify),
        connect_href: ~p"/auth/spotify?code=#{code}"
      }
    ]
  end

  defp spotify_connection(%{premium?: true}), do: :connected
  defp spotify_connection(spotify) when is_map(spotify), do: :not_premium
  defp spotify_connection(_), do: :disconnected

  defp active_service(view, code) do
    Enum.find(music_services(view, code), &(&1.status == :connected))
  end

  defp music_ready?(view, code), do: active_service(view, code) != nil

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(%{view: nil} = assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div data-theme="jam" class="jam-stage min-h-screen flex items-center px-12 lg:px-20">
      <div class="space-y-6">
        <img src={~p"/images/whose-jam-logo.svg"} alt="Whose Jam" class="w-56 -ml-4" />
        <h1 class="font-display text-6xl">No game here</h1>
        <p class="text-2xl text-jam-cream/60">Room {@code} isn't live.</p>
        <.link navigate={~p"/"} class="jam-btn">Back to start</.link>
      </div>
    </div>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        banner: playback_banner(assigns),
        services: music_services(assigns.view, assigns.code),
        active_service: active_service(assigns.view, assigns.code),
        art_url: current_art(assigns.view),
        show_music_prompt?:
          assigns.view.phase == :lobby and not music_ready?(assigns.view, assigns.code) and
            not assigns.music_prompt_dismissed? and not assigns.settings_open?
      )

    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div data-theme="jam" class="jam-stage min-h-screen overflow-hidden">
      <%!-- Apple Music–style ambience: the current song's artwork tints the room. --%>
      <div :if={@art_url} class="jam-ambient" style={"background-image: url('#{@art_url}')"}></div>

      <div
        :if={@spotify_status == :ok}
        id="spotify-player"
        phx-hook="SpotifyPlayer"
        data-token={@spotify_token}
        data-uri={play_uri(@view)}
        class="hidden"
      >
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
        <span :if={@view.phase != :lobby} class="truncate text-jam-cream/60 font-bold">
          {@view.theme.name} · <span class="tracking-widest">{@code}</span>
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
    <div :if={@show_music_prompt?} class="modal modal-open bg-jam-ink/80 backdrop-blur-sm">
      <div class="modal-box max-w-lg space-y-5 border border-jam-cream/10">
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
      </div>
      <div class="modal-backdrop" phx-click="dismiss_music_prompt"></div>
    </div>
    """
  end

  defp music_service_list(assigns) do
    ~H"""
    <ul class="space-y-3">
      <li
        :for={service <- @services}
        class="flex items-center gap-4 rounded-box border border-jam-cream/10 bg-base-200 p-4"
      >
        <div class="grid place-items-center size-11 rounded-full bg-jam-pink text-white shrink-0">
          <.icon name="hero-musical-note" class="size-5" />
        </div>
        <div class="flex-1 min-w-0">
          <p class="font-display text-lg">{service.name}</p>
          <p class={["text-sm", service_status_class(service.status)]}>
            {service_status_text(service)}
          </p>
        </div>
        <a
          href={service.connect_href}
          class={["jam-btn text-sm !px-4 !py-2", service.status == :connected && "jam-btn-ghost"]}
        >
          {service_action(service.status)}
        </a>
      </li>
      <li class="flex items-center gap-4 rounded-box border border-dashed border-jam-cream/15 p-4 text-base-content/50">
        <div class="grid place-items-center size-11 rounded-full bg-base-300 shrink-0">
          <.icon name="hero-plus" class="size-5" />
        </div>
        <p class="text-sm">More music services coming soon.</p>
      </li>
    </ul>
    """
  end

  defp service_status_text(%{status: :connected, name: name}), do: "Connected — #{name} is ready."

  defp service_status_text(%{status: :not_premium}),
    do: "This account isn't Premium. Reconnect with a Premium account."

  defp service_status_text(%{requirement: requirement}), do: requirement

  defp service_status_class(:connected), do: "text-success"
  defp service_status_class(:not_premium), do: "text-error"
  defp service_status_class(_), do: "text-base-content/60"

  defp service_action(:connected), do: "Switch account"
  defp service_action(:not_premium), do: "Reconnect"
  defp service_action(_), do: "Connect"

  # ---- settings panel ----------------------------------------------------

  defp settings_panel(assigns) do
    assigns = assign(assigns, estimate: runtime_estimate(assigns.view))

    ~H"""
    <div
      :if={@settings_open?}
      class="modal modal-open bg-jam-ink/80 backdrop-blur-sm"
      phx-window-keydown="close_settings"
      phx-key="Escape"
    >
      <div class="modal-box max-w-2xl space-y-7 border border-jam-cream/10">
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
              Player is live on this screen.
            <% else %>
              Starting the player on this screen…
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
                label="Answer timer (s)"
                value={@view.config.answer_timer_s}
                min="10"
              />
              <.input
                type="number"
                id="vote_delay_s"
                name="vote_delay_s"
                label="Listen before voting opens (s)"
                value={@view.config.vote_delay_s}
                min="0"
              />
              <.input
                type="number"
                id="vote_timer_s"
                name="vote_timer_s"
                label="Vote countdown once most have voted (s)"
                value={@view.config.vote_timer_s}
                min="5"
              />
              <.input
                type="number"
                id="questions_per_player"
                name="questions_per_player"
                label="Questions per player"
                value={@view.config.questions_per_player}
                min="1"
              />
              <.input
                type="select"
                id="min_players"
                name="min_players"
                label="Players needed to start"
                value={@view.config.min_players}
                options={Enum.map(2..8, &{Integer.to_string(&1), &1})}
              />
              <div class="flex flex-col justify-end gap-1">
                <.input
                  type="checkbox"
                  id="subrounds_enabled?"
                  name="subrounds_enabled?"
                  label="Sub-rounds (split multi-style themes)"
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
      </div>
      <div class="modal-backdrop" phx-click="close_settings"></div>
    </div>
    """
  end

  # ---- lobby --------------------------------------------------------------

  defp lobby(assigns) do
    assigns =
      assign(assigns,
        player_count: length(assigns.view.players),
        min_players: assigns.view.config.min_players,
        music_ready?: assigns.active_service != nil
      )

    ~H"""
    <div class="min-h-screen flex flex-col justify-center gap-12 px-12 lg:px-20 pt-28 pb-16">
      <div class="space-y-3 max-w-3xl">
        <p class="jam-eyebrow">Tonight's vibe</p>
        <h1 class="font-display text-6xl xl:text-7xl leading-none">{@view.theme.name}</h1>
        <p class="text-xl text-jam-cream/70">{@view.theme.description}</p>
      </div>

      <div class="grid xl:grid-cols-[auto_minmax(18rem,1fr)] gap-14 xl:gap-24 items-start">
        <div class="flex flex-col sm:flex-row sm:items-center gap-10">
          <div class="rounded-[1.75rem] bg-jam-cream p-4 shrink-0">{raw(@qr_svg)}</div>
          <div class="space-y-2">
            <p class="jam-eyebrow">Room code</p>
            <p class="font-display text-8xl xl:text-9xl leading-none tracking-[0.12em] whitespace-nowrap">
              {@view.code}
            </p>
            <p class="text-lg text-jam-cream/60 pt-2">
              Scan the code or go to <br />
              <span class="whitespace-nowrap font-bold text-jam-cream">{@join_url}</span>
            </p>
          </div>
        </div>

        <div class="space-y-6">
          <div class="space-y-4">
            <p class="jam-eyebrow">
              Players <span class="text-jam-cream">{@player_count}/8</span>
            </p>
            <p :if={@view.players == []} class="text-jam-cream/50 text-xl">
              Waiting for players to join…
            </p>
            <div class="flex flex-wrap gap-3">
              <span
                :for={p <- @view.players}
                class={["jam-chip jam-chip-on text-2xl", p.connected? || "opacity-40"]}
              >
                {p.name}
              </span>
            </div>
          </div>

          <div :if={@view.audience != []} class="space-y-2">
            <p class="jam-eyebrow">Audience ({length(@view.audience)})</p>
            <div class="flex flex-wrap gap-2">
              <span :for={p <- @view.audience} class="jam-chip text-lg">{p.name}</span>
            </div>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-6">
        <button
          phx-click="start"
          disabled={not can_start?(@player_count, @min_players, @music_ready?)}
          class="jam-btn text-2xl !px-12"
        >
          Start game
        </button>
        <%= cond do %>
          <% not @music_ready? -> %>
            <button
              type="button"
              phx-click="open_settings"
              class="text-lg font-bold text-jam-orange underline underline-offset-4 cursor-pointer"
            >
              Connect a music service to start
            </button>
          <% @player_count < @min_players -> %>
            <p class="text-lg text-jam-cream/60">
              Waiting for at least {@min_players} players ({@player_count} joined)
            </p>
          <% true -> %>
            <p class="text-lg text-jam-cream/80 font-bold">Everyone in? Let's go.</p>
        <% end %>
      </div>
    </div>
    """
  end

  # ---- answering ----------------------------------------------------------

  defp answering(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col justify-center gap-12 px-12 lg:px-20 pt-28 pb-16">
      <div class="space-y-3">
        <p :if={@view.subround_total > 1} class="jam-eyebrow">
          Sub-round {@view.subround_index + 1} of {@view.subround_total}
        </p>
        <h1 class="font-display text-7xl xl:text-8xl leading-none">Heads down 🎧</h1>
        <p class="text-2xl text-jam-cream/70">Everyone's picking their songs.</p>
      </div>

      <div class="grid lg:grid-cols-[auto_minmax(0,40rem)] gap-14 lg:gap-24 items-center">
        <div :if={@view.answering} class="space-y-1">
          <p class="jam-eyebrow">Time left</p>
          <p
            id="answer-countdown"
            phx-hook="Countdown"
            data-deadline={@view.answering.deadline_ms}
            class="font-display text-9xl leading-none tabular-nums text-jam-orange"
          >
          </p>
        </div>

        <div :if={@view.answering} class="space-y-4">
          <div :for={p <- @view.players} class="grid grid-cols-[10rem_1fr_4rem] items-center gap-4">
            <span class="text-2xl font-bold truncate">{p.name}</span>
            <% prog = Map.get(@view.answering.progress, p.id, %{submitted: 0, total: 0}) %>
            <div class="h-5 rounded-full bg-jam-cream/10 overflow-hidden">
              <div
                class="h-full rounded-full bg-gradient-to-r from-jam-purple via-jam-pink to-jam-orange transition-[width] duration-500"
                style={progress_style(prog)}
              >
              </div>
            </div>
            <span class="text-2xl font-bold tabular-nums text-jam-cream/70">
              {prog.submitted}/{prog.total}
            </span>
          </div>
        </div>
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

  defp playing(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col lg:flex-row lg:items-center gap-10 xl:gap-16 px-12 lg:px-20 pt-28 pb-16">
      <div class="shrink-0">
        <%= if @art_url do %>
          <img src={@art_url} alt="Album art" class="jam-art size-80 lg:size-[28rem] xl:size-[34rem]" />
        <% else %>
          <div class="size-80 lg:size-[28rem] grid place-items-center rounded-[2rem] bg-jam-cream/5">
            <span class="text-9xl">🎵</span>
          </div>
        <% end %>
      </div>

      <div class="flex-1 max-w-3xl space-y-7">
        <p class="flex items-center gap-3 jam-eyebrow">
          <span :if={@view.round_state != :results} class="jam-eq text-base" aria-hidden="true">
            <span></span><span></span><span></span><span></span>
          </span>
          Round {@view.round.index + 1} of {@view.round.total} · {round_state_label(@view.round_state)}
        </p>
        <div>
          <h1 class="font-display text-6xl xl:text-7xl leading-[1.02]">{@view.round.song.name}</h1>
          <p class="text-3xl text-jam-cream/70 mt-3 font-bold">{@view.round.song.artist}</p>
        </div>

        <%= case @view.round_state do %>
          <% :revealing -> %>
            <div class="space-y-2">
              <p class="font-display text-4xl text-jam-orange">{reveal_prompt(@view.round.style)}</p>
              <p class="text-2xl text-jam-cream/70">
                Voting opens in
                <span
                  id="votes-open-countdown"
                  phx-hook="Countdown"
                  data-deadline={@view.round.votes_open_ms}
                  class="font-display text-jam-cream tabular-nums"
                ></span>
              </p>
            </div>
          <% :voting -> %>
            {voting(assigns)}
          <% :results -> %>
            {results(assigns)}
          <% _ -> %>
        <% end %>
      </div>
    </div>
    """
  end

  defp voting(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-end gap-6">
        <p class="font-display text-4xl text-jam-orange">{vote_prompt(@view.round.style)}</p>
        <span
          :if={@view.round.deadline_ms}
          id="vote-countdown"
          phx-hook="Countdown"
          data-deadline={@view.round.deadline_ms}
          class="font-display text-7xl leading-none tabular-nums"
        ></span>
      </div>
      <p :if={!@view.round.deadline_ms} class="text-xl text-jam-cream/70">
        Vote on your phone — the countdown starts once most of you are in.
      </p>

      <div class="space-y-3">
        <p class="jam-eyebrow">Votes in · {@view.round.votes_received}</p>
        <div class="flex flex-wrap gap-2">
          <span
            :for={p <- @view.players ++ @view.audience}
            class={["jam-chip text-xl", p.id in @view.round.voters && "jam-chip-on"]}
          >
            <.icon :if={p.id in @view.round.voters} name="hero-check" class="size-5" />
            {p.name}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp results(assigns) do
    assigns =
      assign(assigns, submitter_name: name_of(assigns.view, assigns.view.round.submitter_id))

    ~H"""
    <div class="space-y-6">
      <div :if={@view.round.style == :guess_question} class="space-y-2">
        <p class="jam-eyebrow">The prompt was</p>
        <p class="font-display text-5xl leading-tight text-jam-orange">
          {@view.round.correct_prompt}
        </p>
        <p class="text-2xl text-jam-cream/75">
          submitted by <span class="font-bold text-jam-cream">{@submitter_name}</span>
        </p>
      </div>
      <div :if={@view.round.style != :guess_question} class="space-y-1">
        <p class="jam-eyebrow">It was</p>
        <p class="font-display text-8xl leading-none text-jam-pink">{@submitter_name}</p>
      </div>

      <% gains = round_gains(@view) %>
      <div :if={gains != []} class="flex flex-wrap gap-3">
        <span :for={{name, delta} <- gains} class="jam-chip text-2xl">
          {name} <span class="font-display text-jam-orange">+{delta}</span>
        </span>
      </div>

      {scoreboard(assigns)}
    </div>
    """
  end

  # ---- finished -----------------------------------------------------------

  defp finished(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col justify-center gap-12 px-12 lg:px-20 pt-28 pb-16">
      <div class="space-y-2">
        <p class="jam-eyebrow">Final scores</p>
        <h1 class="font-display text-7xl xl:text-8xl leading-none">🏆 {winner_names(@view)}</h1>
      </div>

      <div class="grid md:grid-cols-2 gap-12 max-w-5xl">
        <div class="space-y-3">
          <p class="jam-eyebrow">Players</p>
          <ul class="space-y-2">
            <li
              :for={{p, rank} <- ranked(@view, @view.players) |> Enum.with_index(1)}
              class={[
                "flex items-center justify-between text-3xl px-5 py-3 rounded-2xl",
                if(p.id in winner_ids(@view, :players),
                  do: "bg-jam-orange text-jam-ink font-bold",
                  else: "jam-panel"
                )
              ]}
            >
              <span><span class="opacity-50 tabular-nums">{rank}.</span> {p.name}</span>
              <span class="font-display">{score_of(@view, p.id)}</span>
            </li>
          </ul>
        </div>

        <div :if={@view.audience != []} class="space-y-3">
          <p class="jam-eyebrow">Audience</p>
          <ul class="space-y-2">
            <li
              :for={p <- ranked(@view, @view.audience)}
              class="jam-panel flex items-center justify-between text-2xl px-5 py-3 text-jam-cream/80"
            >
              <span>{p.name}</span>
              <span class="font-display">{score_of(@view, p.id)}</span>
            </li>
          </ul>
        </div>
      </div>

      <div>
        <button phx-click="play_again" class="jam-btn text-xl">Play again with these players</button>
      </div>
    </div>
    """
  end

  # A compact running scoreboard for between rounds (players only — the
  # "official" board is submitters).
  defp scoreboard(assigns) do
    ~H"""
    <div class="jam-panel p-5 space-y-2 max-w-xl">
      <p class="jam-eyebrow">Scoreboard</p>
      <ul class="space-y-1.5">
        <li
          :for={p <- ranked(@view, @view.players)}
          class="flex items-center justify-between text-2xl"
        >
          <span class="font-bold">{p.name}</span>
          <span class="font-display text-jam-orange">{score_of(@view, p.id)}</span>
        </li>
      </ul>
    </div>
    """
  end

  # =========================================================================
  # View helpers
  # =========================================================================

  defp current_art(%{phase: :playing, round: %{song: %{album_art_url: url}}})
       when is_binary(url) and url != "",
       do: url

  defp current_art(_view), do: nil

  defp can_start?(player_count, min_players, music_ready?),
    do: player_count >= min_players and music_ready?

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

  defp round_state_label(:revealing), do: "Now playing"
  defp round_state_label(:voting), do: "Voting"
  defp round_state_label(:results), do: "Reveal"
  defp round_state_label(_), do: ""

  defp reveal_prompt(:guess_who), do: "Whose jam is this? 👀"
  defp reveal_prompt(:guess_question), do: "What prompt was this answering? 🤔"
  defp reveal_prompt(_), do: "Listen up…"

  defp vote_prompt(:guess_who), do: "Who submitted it?"
  defp vote_prompt(:guess_question), do: "Which prompt was it?"
  defp vote_prompt(_), do: "Cast your vote!"

  defp name_of(view, id) do
    case Enum.find(view.players ++ view.audience, &(&1.id == id)) do
      nil -> "someone"
      p -> p.name
    end
  end

  defp round_gains(view) do
    deltas = view.round.deltas || %{}

    deltas
    |> Enum.filter(fn {_id, delta} -> delta > 0 end)
    |> Enum.map(fn {id, delta} -> {name_of(view, id), delta} end)
    |> Enum.sort_by(fn {_name, delta} -> -delta end)
  end

  defp score_of(view, id), do: Map.get(view.scores, id, 0)

  defp ranked(view, participants) do
    Enum.sort_by(participants, &score_of(view, &1.id), :desc)
  end

  defp winner_ids(view, key) do
    case view.winners do
      %{^key => ids} -> ids
      _ -> []
    end
  end

  defp winner_names(view) do
    case winner_ids(view, :players) do
      [] ->
        "Game over"

      ids ->
        ids
        |> Enum.map(&name_of(view, &1))
        |> Enum.join(" & ")
    end
  end
end
