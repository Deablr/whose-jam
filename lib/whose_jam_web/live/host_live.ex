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
  broadcasts `{:game_ended, reason}`, and every host screen goes back to the
  start page.
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.Game
  alias WhoseJam.Game.Config
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
    {:noreply, socket}
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

  defp ended_message(:host_ended), do: "Thanks for playing! That game is over."
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

  defp announce_connected(socket, provider, auth) do
    if provider.eligible?(auth),
      do: put_flash(socket, :info, "#{provider.name()} connected."),
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
    |> EQRCode.svg(width: 300, background_color: "#fbf1e1", color: "#120726")
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
  defp video_frame_class, do: "aspect-video w-[min(28rem,calc(100vw-6rem))] xl:w-[36rem]"

  # Audio providers never show their player. A video provider's player is
  # placed over the room the playing layout reserves for it: that layout pads
  # 7rem above and 4rem below and centres its row from `lg` up, so the row's
  # middle is 1.5rem below the stage's; below `lg` the row starts at the top.
  # It is positioned in the stage (`.jam-stage` is `position: relative`), not
  # fixed to the viewport, so it scrolls with the layout it sits over.
  defp player_class(false, _playing?), do: "hidden"

  defp player_class(true, false),
    do: ["pointer-events-none absolute left-0 top-0 -z-10 opacity-0", video_frame_class()]

  defp player_class(true, true) do
    [
      "absolute z-20 left-12 top-28 overflow-hidden rounded-[2rem] bg-black shadow-2xl",
      "lg:left-20 lg:top-[calc(50%+1.5rem)] lg:-translate-y-1/2",
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
    services = music_services(assigns.view, assigns.code)
    active_service = Enum.find(services, &(&1.status == :connected))

    assigns =
      assign(assigns,
        banner: playback_banner(assigns),
        services: services,
        active_service: active_service,
        art_url: current_art(assigns.view),
        show_music_prompt?:
          assigns.view.phase == :lobby and is_nil(active_service) and
            not assigns.music_prompt_dismissed? and not assigns.settings_open?,
        show_music_question?:
          assigns.view.phase == :lobby and unanswered_question?(active_service) and
            not assigns.music_question_dismissed? and not assigns.settings_open?
      )

    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div data-theme="jam" class="jam-stage min-h-screen overflow-hidden">
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

  defp service_status_text(%{status: :ineligible, ineligible_message: message}), do: message

  defp service_status_text(%{status: :unconfigured}), do: "Not configured on this server."

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
      class="max-w-2xl"
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
              label="Vote countdown once most have voted (s)"
              value={@view.config.vote_timer_s}
              min={Config.range(:vote_timer_s).first}
              max={Config.range(:vote_timer_s).last}
            />
            <.input
              type="number"
              id="questions_per_player"
              name="questions_per_player"
              label="Questions per player"
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
    assigns =
      assign(assigns,
        player_count: length(assigns.view.players),
        min_players: assigns.view.config.min_players
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
          <div class="rounded-[1.75rem] bg-jam-cream p-4 shrink-0"><.qr_code svg={@qr_svg} /></div>
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
          disabled={@player_count < @min_players or is_nil(@active_service)}
          class="jam-btn text-2xl !px-12"
        >
          Start game
        </button>
        <%= cond do %>
          <% is_nil(@active_service) -> %>
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

      <div
        :if={@active_service && @active_service.warning}
        id="music-warning"
        class="-mt-6 flex max-w-3xl items-start gap-3 rounded-2xl border border-jam-orange/40 bg-jam-orange/10 px-5 py-4 text-jam-cream/90"
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
        <%= cond do %>
          <% @music_video? -> %>
            <%!-- Holds the space the video player (see render/1) sits over. --%>
            <div class={video_frame_class()} aria-hidden="true"></div>
          <% @art_url -> %>
            <img
              src={@art_url}
              alt="Album art"
              class="jam-art size-80 lg:size-[28rem] xl:size-[34rem]"
            />
          <% true -> %>
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

        <%!-- Guess-who rounds say what the song was picked for. --%>
        <figure
          :if={@view.round.prompt}
          id="round-prompt"
          class="space-y-2 border-l-4 border-jam-pink pl-5"
        >
          <figcaption class="jam-eyebrow">The prompt</figcaption>
          <blockquote class="font-display text-3xl xl:text-4xl leading-tight text-jam-cream/90">
            {@view.round.prompt}
          </blockquote>
        </figure>

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

      <div class="flex flex-wrap items-center gap-4">
        <button phx-click="play_again" class="jam-btn text-xl">Play again with these players</button>
        <button
          id="exit-game"
          type="button"
          phx-click="exit_game"
          data-confirm="End the game for everyone?"
          class="jam-btn jam-btn-ghost text-xl transition-colors hover:bg-jam-cream/15"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-6" /> Exit game
        </button>
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
        Enum.map_join(ids, " & ", &name_of(view, &1))
    end
  end
end
