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

  @host_settings ~w(answer_timer_s vote_timer_s questions_per_player
                    subrounds_enabled? allow_vote_change?)

  # Forward only the setting the host just changed. The form posts every field,
  # and untouched ones still hold player-count-derived defaults — sending them
  # would pin those defaults as overrides (e.g. an empty lobby's 15 questions
  # per player sticking after 8 people join).
  defp config_overrides(%{"_target" => [field | _]} = params) when field in @host_settings do
    Map.take(params, [field])
  end

  defp config_overrides(_params), do: %{}

  defp start_error(:not_enough_players), do: "You need at least 3 players to start."
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
    |> EQRCode.svg(width: 320, background_color: "#000000", color: "#ffffff")
  end

  # The URI that should be playing right now: only during the reveal of a round.
  defp play_uri(%{phase: :playing, round_state: :revealing, round: %{song: %{uri: uri}}})
       when is_binary(uri),
       do: uri

  defp play_uri(_view), do: ""

  defp playback_error_message(%{"reason" => "initialization_error"}),
    do:
      "This browser can't play protected Spotify audio (DRM/Widevine unavailable). " <>
        "Use Chrome, Edge, or Firefox with protected content allowed, over https " <>
        "or on this machine via localhost — http on a LAN IP disables DRM."

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
    <div class="min-h-screen grid place-items-center bg-black text-white text-center px-4">
      <div class="space-y-6">
        <h1 class="text-6xl font-black">No game here</h1>
        <p class="text-2xl text-white/60">Room {@code} isn't live.</p>
        <.link navigate={~p"/"} class="btn btn-primary btn-lg">Back to start</.link>
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
        show_music_prompt?:
          assigns.view.phase == :lobby and not music_ready?(assigns.view, assigns.code) and
            not assigns.music_prompt_dismissed? and not assigns.settings_open?
      )

    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div data-theme="dark" class="min-h-screen bg-black text-white overflow-hidden">
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

      <div
        :if={@banner}
        class="fixed top-14 inset-x-0 z-30 bg-amber-500 text-black text-center py-2 px-4 font-semibold"
      >
        Playback unavailable — {@banner}
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
    <header class="fixed top-0 inset-x-0 z-40 h-14 flex items-center justify-between gap-4 px-5 bg-black/70 backdrop-blur border-b border-white/10">
      <div class="flex items-center gap-3 min-w-0 text-white/70">
        <span class="font-black tracking-tight text-white">whose-jam</span>
        <span class="text-white/30">·</span>
        <span class="truncate">{@view.theme.name}</span>
        <span class="text-white/30">·</span>
        <span class="font-mono font-bold tracking-widest text-white">{@code}</span>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <button
          type="button"
          phx-click="open_settings"
          class={[
            "btn btn-sm rounded-full gap-2",
            if(@active_service, do: "btn-ghost text-white/70", else: "btn-warning")
          ]}
        >
          <%= if @active_service do %>
            <span class={[
              "inline-block size-2 rounded-full",
              if(@playback_ready?, do: "bg-emerald-400", else: "bg-white/40")
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
          class="btn btn-sm btn-ghost rounded-full gap-1 text-white/70"
        >
          <.icon name="hero-forward" class="size-4" /> Skip song
        </button>

        <button
          type="button"
          phx-click="open_settings"
          aria-label="Settings"
          class="btn btn-sm btn-ghost btn-circle text-white/70"
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
    <div :if={@show_music_prompt?} class="modal modal-open bg-black/70">
      <div class="modal-box max-w-lg space-y-5">
        <div class="space-y-1">
          <h2 class="text-2xl font-bold">Connect your music</h2>
          <p class="text-base-content/70">
            This screen plays every song the players pick. Connect a music service before you start.
          </p>
        </div>
        {music_service_list(assigns)}
        <div class="modal-action mt-0">
          <button type="button" phx-click="dismiss_music_prompt" class="btn btn-ghost">
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
    <ul class="space-y-2">
      <li
        :for={service <- @services}
        class="flex items-center gap-4 rounded-box border border-base-content/10 bg-base-200 p-4"
      >
        <div class="grid place-items-center size-10 rounded-full bg-base-300 shrink-0">
          <.icon name="hero-musical-note" class="size-5" />
        </div>
        <div class="flex-1 min-w-0">
          <p class="font-semibold">{service.name}</p>
          <p class={["text-sm", service_status_class(service.status)]}>
            {service_status_text(service)}
          </p>
        </div>
        <a
          href={service.connect_href}
          class={[
            "btn btn-sm",
            if(service.status == :connected, do: "btn-ghost", else: "btn-primary")
          ]}
        >
          {service_action(service.status)}
        </a>
      </li>
      <li class="flex items-center gap-4 rounded-box border border-dashed border-base-content/15 p-4 text-base-content/50">
        <div class="grid place-items-center size-10 rounded-full bg-base-300/50 shrink-0">
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
      class="modal modal-open bg-black/70"
      phx-window-keydown="close_settings"
      phx-key="Escape"
    >
      <div class="modal-box max-w-2xl space-y-6">
        <div class="flex items-center justify-between">
          <h2 class="text-2xl font-bold">Settings</h2>
          <button
            type="button"
            phx-click="close_settings"
            aria-label="Close settings"
            class="btn btn-sm btn-ghost btn-circle"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <section class="space-y-3">
          <h3 class="text-sm font-semibold uppercase tracking-wider text-base-content/60">
            Music service
          </h3>
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
          <div class="flex items-baseline justify-between">
            <h3 class="text-sm font-semibold uppercase tracking-wider text-base-content/60">
              Game
            </h3>
            <span class="text-sm text-base-content/60">
              Estimated length: <span class="font-semibold">~{@estimate} min</span>
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
                id="vote_timer_s"
                name="vote_timer_s"
                label="Vote timer (s)"
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
        music_ready?: assigns.active_service != nil
      )

    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center gap-10 px-8 pt-24 pb-12">
      <div class="text-center space-y-2">
        <h1 class="text-5xl font-black">{@view.theme.name}</h1>
        <p class="text-xl text-white/60 max-w-2xl">{@view.theme.description}</p>
      </div>

      <div class="w-full max-w-6xl grid lg:grid-cols-2 gap-12 items-center">
        <div class="flex flex-col sm:flex-row items-center justify-center gap-8">
          <div class="bg-black p-3 rounded-2xl shrink-0">{raw(@qr_svg)}</div>
          <div class="text-center sm:text-left">
            <p class="text-2xl text-white/60 uppercase tracking-widest">Room code</p>
            <p class="text-8xl font-black font-mono tracking-widest">{@view.code}</p>
            <p class="text-lg text-white/50 mt-2 break-all">Scan or go to {@join_url}</p>
          </div>
        </div>

        <div class="space-y-6 text-center lg:text-left">
          <div>
            <h2 class="text-2xl font-semibold mb-3">
              Players <span class="text-white/50">({@player_count}/8)</span>
            </h2>
            <p :if={@view.players == []} class="text-white/40 text-xl">
              Waiting for players to join…
            </p>
            <div class="flex flex-wrap justify-center lg:justify-start gap-3">
              <span
                :for={p <- @view.players}
                class={[
                  "px-5 py-2 rounded-full text-2xl font-semibold bg-white/10",
                  p.connected? || "opacity-40"
                ]}
              >
                {p.name}
              </span>
            </div>
          </div>

          <div :if={@view.audience != []}>
            <h3 class="text-lg font-semibold text-white/60 mb-1">
              Audience ({length(@view.audience)})
            </h3>
            <div class="flex flex-wrap justify-center lg:justify-start gap-2">
              <span :for={p <- @view.audience} class="px-3 py-1 rounded-full text-lg bg-white/5">
                {p.name}
              </span>
            </div>
          </div>
        </div>
      </div>

      <div class="flex flex-col items-center gap-3">
        <button
          phx-click="start"
          disabled={not can_start?(@player_count, @music_ready?)}
          class="btn btn-primary btn-lg px-12 text-xl"
        >
          Start game
        </button>
        <%= cond do %>
          <% not @music_ready? -> %>
            <button
              type="button"
              phx-click="open_settings"
              class="text-lg text-amber-400 underline underline-offset-4"
            >
              Connect a music service to start
            </button>
          <% @player_count < 3 -> %>
            <p class="text-lg text-white/50">
              Waiting for at least 3 players ({@player_count} joined)
            </p>
          <% true -> %>
            <p class="text-lg text-white/50">Everyone in? Let's go.</p>
        <% end %>
      </div>
    </div>
    """
  end

  # ---- answering ----------------------------------------------------------

  defp answering(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center gap-10 px-8 pt-20 text-center">
      <div class="space-y-2">
        <h1 class="text-7xl font-black">Heads down! 🎧</h1>
        <p class="text-3xl text-white/60">Everyone's picking their songs.</p>
        <p :if={@view.subround_total > 1} class="text-xl text-white/40">
          Sub-round {@view.subround_index + 1} of {@view.subround_total}
        </p>
      </div>

      <div :if={@view.answering} class="text-center">
        <p class="text-2xl text-white/50 uppercase tracking-widest">Time left</p>
        <p
          id="answer-countdown"
          phx-hook="Countdown"
          data-deadline={@view.answering.deadline_ms}
          class="text-8xl font-black font-mono"
        >
        </p>
      </div>

      <div :if={@view.answering} class="w-full max-w-2xl space-y-3">
        <div :for={p <- @view.players} class="flex items-center gap-4">
          <span class="w-40 text-right text-2xl truncate">{p.name}</span>
          <% prog = Map.get(@view.answering.progress, p.id, %{submitted: 0, total: 0}) %>
          <div class="flex-1 h-6 rounded-full bg-white/10 overflow-hidden">
            <div class="h-full bg-emerald-500" style={progress_style(prog)}></div>
          </div>
          <span class="w-16 text-2xl font-mono">{prog.submitted}/{prog.total}</span>
        </div>
      </div>
    </div>
    """
  end

  # ---- playing ------------------------------------------------------------

  defp playing(%{view: %{round: nil}} = assigns) do
    ~H"""
    <div class="min-h-screen grid place-items-center text-center">
      <p class="text-4xl text-white/60">Loading the next song…</p>
    </div>
    """
  end

  defp playing(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col lg:flex-row items-center justify-center gap-12 px-10 pt-24 pb-12">
      <div class="shrink-0">
        <%= if @view.round.song.album_art_url do %>
          <img
            src={@view.round.song.album_art_url}
            alt="Album art"
            class="size-72 lg:size-96 rounded-3xl shadow-2xl object-cover"
          />
        <% else %>
          <div class="size-72 lg:size-96 rounded-3xl bg-white/10 grid place-items-center">
            <span class="text-9xl">🎵</span>
          </div>
        <% end %>
      </div>

      <div class="flex-1 max-w-2xl space-y-6 text-center lg:text-left">
        <p class="text-2xl uppercase tracking-widest text-white/50">
          Round {@view.round.index + 1} of {@view.round.total} · {round_state_label(@view.round_state)}
        </p>
        <div>
          <h1 class="text-6xl font-black leading-tight">{@view.round.song.name}</h1>
          <p class="text-3xl text-white/60 mt-2">{@view.round.song.artist}</p>
        </div>

        <%= case @view.round_state do %>
          <% :revealing -> %>
            <p class="text-3xl text-white/70">
              {reveal_prompt(@view.round.style)}
            </p>
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
    <div class="space-y-5">
      <div class="flex items-center gap-4 justify-center lg:justify-start">
        <p class="text-3xl font-semibold">{vote_prompt(@view.round.style)}</p>
        <span
          id="vote-countdown"
          phx-hook="Countdown"
          data-deadline={@view.round.deadline_ms}
          class="text-5xl font-black font-mono text-amber-400"
        ></span>
      </div>

      <div>
        <p class="text-xl text-white/50 mb-2">Votes in ({@view.round.votes_received})</p>
        <div class="flex flex-wrap gap-2 justify-center lg:justify-start">
          <span
            :for={p <- @view.players ++ @view.audience}
            class={[
              "px-4 py-2 rounded-full text-xl font-medium",
              if(p.id in @view.round.voters, do: "bg-emerald-500 text-black", else: "bg-white/10")
            ]}
          >
            <%= if p.id in @view.round.voters do %>
              ✓ {p.name}
            <% else %>
              {p.name}
            <% end %>
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
    <div class="space-y-5">
      <div :if={@view.round.style == :guess_question} class="text-center lg:text-left">
        <p class="text-2xl text-white/50">The prompt was…</p>
        <p class="text-5xl font-black text-emerald-400 leading-tight">{@view.round.correct_prompt}</p>
        <p class="text-2xl text-white/60 mt-2">submitted by {@submitter_name}</p>
      </div>
      <div :if={@view.round.style != :guess_question} class="text-center lg:text-left">
        <p class="text-2xl text-white/50">It was…</p>
        <p class="text-6xl font-black text-emerald-400">{@submitter_name}</p>
      </div>

      <% gains = round_gains(@view) %>
      <div :if={gains != []} class="flex flex-wrap gap-3 justify-center lg:justify-start">
        <span
          :for={{name, delta} <- gains}
          class="px-4 py-2 rounded-full bg-white/10 text-2xl font-semibold"
        >
          {name} <span class="text-emerald-400">+{delta}</span>
        </span>
      </div>

      {scoreboard(assigns)}
    </div>
    """
  end

  # ---- finished -----------------------------------------------------------

  defp finished(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center gap-10 px-8 pt-24 pb-12 text-center">
      <div class="space-y-2">
        <p class="text-3xl text-white/50 uppercase tracking-[0.3em]">Final scores</p>
        <h1 class="text-7xl font-black">🏆 {winner_names(@view)}</h1>
      </div>

      <div class="w-full max-w-3xl grid md:grid-cols-2 gap-8">
        <div>
          <h2 class="text-3xl font-bold mb-3 border-b border-white/20 pb-1">Players</h2>
          <ul class="space-y-2">
            <li
              :for={{p, rank} <- ranked(@view, @view.players) |> Enum.with_index(1)}
              class={[
                "flex items-center justify-between text-3xl px-4 py-2 rounded-xl",
                if(p.id in winner_ids(@view, :players),
                  do: "bg-amber-400 text-black font-black",
                  else: "bg-white/5"
                )
              ]}
            >
              <span>{rank}. {p.name}</span>
              <span class="font-mono">{score_of(@view, p.id)}</span>
            </li>
          </ul>
        </div>

        <div :if={@view.audience != []}>
          <h2 class="text-3xl font-bold mb-3 border-b border-white/20 pb-1 text-white/70">
            Audience
          </h2>
          <ul class="space-y-2">
            <li
              :for={p <- ranked(@view, @view.audience)}
              class="flex items-center justify-between text-2xl px-4 py-2 rounded-xl bg-white/5 text-white/70"
            >
              <span>{p.name}</span>
              <span class="font-mono">{score_of(@view, p.id)}</span>
            </li>
          </ul>
        </div>
      </div>

      <button phx-click="play_again" class="btn btn-primary btn-lg px-10 text-xl">
        Play again with these players
      </button>
    </div>
    """
  end

  # A compact running scoreboard for between rounds (players only — the
  # "official" board is submitters).
  defp scoreboard(assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xl text-white/50 mb-2">Scoreboard</p>
      <ul class="space-y-1">
        <li
          :for={p <- ranked(@view, @view.players)}
          class="flex items-center justify-between text-2xl px-3 py-1 rounded-lg bg-white/5"
        >
          <span>{p.name}</span>
          <span class="font-mono">{score_of(@view, p.id)}</span>
        </li>
      </ul>
    </div>
    """
  end

  # =========================================================================
  # View helpers
  # =========================================================================

  defp can_start?(player_count, music_ready?), do: player_count >= 3 and music_ready?

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
  defp round_state_label(:voting), do: "Vote!"
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
