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
  alias WhoseJam.Game.{Awards, Config, Standings}
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
      _ -> {:noreply, put_flash(socket, :error, "Couldn’t save that answer. Please try again.")}
    end
  end

  def handle_event("answer_music_question", _params, socket) do
    {:noreply, put_flash(socket, :error, "Couldn’t save that answer. Please try again.")}
  end

  def handle_event("set_config", params, socket) do
    Game.set_config(socket.assigns.code, config_overrides(params))
    {:noreply, socket}
  end

  # A stepper's − or + (or a number in a row of them): the setting and the
  # value it moves to, which the game clamps to its range.
  def handle_event("step_config", params, socket) do
    Game.set_config(socket.assigns.code, step_overrides(params))
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

  defp step_overrides(%{"key" => key, "to" => to})
       when key in @host_settings and is_binary(to),
       do: %{key => to}

  defp step_overrides(_params), do: %{}

  # What the closing card remembers of the game: who took it (nobody, when
  # everyone tied).
  defp closing(view) do
    board = Standings.rank(view.players, view.scores)

    winners =
      case winner_rows(board) do
        [_] = winners -> winners
        winners when length(winners) == length(board) -> []
        winners -> winners
      end

    # The night's songs, as a row of small prints, each with whose it was.
    songs =
      for song <- Enum.take(view[:playlist] || [], 8) do
        Map.put(song, :owner, name_of(view, song.player_id))
      end

    %{winners: winners, songs: songs}
  end

  defp ended_message(:host_ended), do: "Thanks for playing."
  defp ended_message(:idle), do: "That game closed after sitting idle."
  defp ended_message(_reason), do: "That game has ended."

  defp start_error(:not_enough_players), do: "Not enough players have joined yet."
  defp start_error(:not_authenticated), do: "Connect a music service first."
  defp start_error(:already_started), do: "The game has already started."
  defp start_error(_), do: "Couldn’t start the game. Please try again."

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
               "The game has started — you can’t switch music service now."
             )}

          _ ->
            {:noreply, put_flash(socket, :error, "Couldn’t connect #{provider.name()}.")}
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
      :error -> {:unavailable, "That music service isn’t available on this server."}
    end
  end

  defp usable_music(%{music: %{eligible?: false}} = view),
    do: {:unavailable, ineligible_message(view)}

  defp usable_music(_view), do: {:unavailable, "No music service is connected."}

  defp ineligible_message(%{music: %{id: id}}) do
    case Music.fetch_provider(id) do
      {:ok, provider} -> provider.ineligible_message()
      :error -> "That music account can’t play full songs."
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
        <p class="text-2xl text-jam-cream/60">Room {@code} isn’t live.</p>
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
      <%!-- The header every screen of the night has, with its one-line
           wordmark (the speech-bubble logo is the home screen's). --%>
      <header class="fixed inset-x-0 top-0 flex h-20 items-center px-12 lg:px-20">
        <.wordmark class="shrink-0 text-[2.1rem]" />
      </header>
      <div class="jam-rise flex flex-col items-center gap-9 text-center">
        <h1 class="font-display text-[5.5rem] leading-none">Thanks for playing</h1>
        <%!-- Who took it: their name on the prize's orange tape, and the
             points in orange, as every point is. --%>
        <p
          :if={@closing.winners != []}
          id="closing-line"
          class="flex flex-wrap items-center justify-center gap-x-3 gap-y-3 text-4xl font-bold text-jam-cream/75"
        >
          <%= for {winner, i} <- Enum.with_index(@closing.winners) do %>
            <span :if={i > 0} class={i < length(@closing.winners) - 1 && "-ml-2"}>
              {if i == length(@closing.winners) - 1, do: "&", else: ","}
            </span>
            <.name_tape
              player_id={winner.id}
              name={winner.name}
              class="jam-tape-orange px-4 py-2 text-[2.4rem]"
            />
          <% end %>
          <span>
            {if match?([_], @closing.winners), do: "won with", else: "shared the win on"}
            <span class="font-display text-jam-orange">{hd(@closing.winners).score}</span>
            {if hd(@closing.winners).score == 1, do: "point", else: "points"}
          </span>
        </p>
        <%!-- The night's songs, as a row of small prints laid on the table,
             each with whose it was on their tape: the album art says
             goodnight. --%>
        <ul
          :if={@closing.songs != []}
          id="closing-songs"
          class="mt-2 flex flex-wrap justify-center gap-x-5 gap-y-10"
        >
          <%!-- Laid down by hand: each print at its own angle and height. --%>
          <li
            :for={song <- @closing.songs}
            class="jam-paper relative w-[9rem] p-1.5 pb-6 text-jam-ink odd:!rotate-[-2.5deg] even:!rotate-[2deg] [&:nth-child(3n)]:translate-y-2 [&:nth-child(4n+1)]:-translate-y-1.5"
          >
            <img
              :if={song[:album_art_url]}
              src={song.album_art_url}
              alt=""
              class="aspect-square w-full object-cover"
            />
            <div
              :if={!song[:album_art_url]}
              class="grid aspect-square w-full place-items-center bg-jam-ink/10"
              aria-hidden="true"
            >
              <.icon name="hero-musical-note-solid" class="size-10 text-jam-ink/40" />
            </div>
            <.name_tape
              :if={song.owner}
              player_id={song.player_id}
              name={song.owner}
              class="absolute -bottom-5 left-1/2 max-w-[9rem] -translate-x-1/2 text-[1.6rem]"
            />
          </li>
        </ul>
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
          # The host’s quick-reveals choice retimes every beat (app.css).
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
      <%!-- Softer at the end of the game, where it sits behind a table. --%>
      <div
        :if={@art_url}
        class={["jam-ambient", @view.phase == :finished && "jam-ambient-soft"]}
        aria-hidden="true"
      >
        <img src={@art_url} alt="" />
      </div>

      {top_bar(assigns)}

      <div :if={@banner} class="fixed bottom-6 right-6 z-30 max-w-md">
        <div class="flex items-start gap-3 rounded-2xl bg-jam-orange px-4 py-3 text-sm text-jam-ink font-bold shadow-xl">
          <.icon name="hero-exclamation-triangle-solid" class="size-5 shrink-0 mt-0.5" />
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
    <header class="fixed top-0 inset-x-0 z-40 h-20 flex items-center justify-between gap-6 px-12 lg:px-20">
      <div class="flex items-center gap-5 min-w-0">
        <.wordmark class="shrink-0 text-[2.1rem]" />
      </div>

      <div class="flex items-center gap-3 shrink-0">
        <%!-- The host's controls, quiet until wanted. --%>
        <%!-- Out of the room's way while a game plays: there until pointed
             at (or tabbed to), and in the lobby, where they are needed. --%>
        <div class={[
          "flex items-center gap-1.5 transition-opacity duration-300 hover:opacity-100 focus-within:opacity-100",
          if(@view.phase == :lobby or is_nil(@active_service), do: "opacity-90", else: "opacity-0")
        ]}>
          <button
            type="button"
            phx-click="open_settings"
            class={
              [
                "jam-chip text-lg cursor-pointer",
                # Until there is music, this is the screen's one thing to do
                # (Start can't be pressed yet): its one pink button.
                !@active_service && "!bg-jam-pink !text-jam-ink"
              ]
            }
          >
            <%= if @active_service do %>
              <%!-- Ready to play: the game's own "done" mark; getting ready, a
                   quiet one. --%>
              <.icon
                name={
                  if @playback_ready?,
                    do: "hero-check-circle-solid",
                    else: "hero-ellipsis-horizontal-circle"
                }
                class={[
                  "size-5 shrink-0",
                  if(@playback_ready?, do: "text-jam-mint", else: "text-jam-cream/50")
                ]}
              />
              {@active_service.name}
              <.icon
                :if={@active_service.warning}
                name="hero-exclamation-triangle-solid"
                class="size-5 text-jam-orange"
              />
            <% else %>
              <.icon name="hero-musical-note-solid" class="size-5" /> Connect music
            <% end %>
          </button>

          <button
            :if={@view.phase == :playing}
            type="button"
            phx-click="skip_song"
            data-confirm="Skip this song and move on?"
            class="jam-chip text-lg cursor-pointer"
          >
            <.icon name="hero-forward-mini" class="size-5" /> Skip
          </button>

          <button
            type="button"
            phx-click="open_settings"
            aria-label="Settings"
            class="jam-chip !px-3 cursor-pointer"
          >
            <.icon name="hero-cog-6-tooth-mini" class="size-6" />
          </button>
        </div>

        <%!-- Where to join stays readable all game, for anyone who turns up
             late: a ticket with the address on its stub and the room code
             on the rest. --%>
        <%!-- A step down while a game plays, so the song and the answer
             win the first glance. --%>
        <div :if={@view.phase != :lobby} class="jam-lift opacity-80">
          <p class="jam-ticket flex items-stretch [--jam-notch:0.35rem]">
            <span
              id="join-at"
              class="flex items-center py-1.5 pl-4 pr-3 text-[1.4rem] font-bold text-jam-ink/70"
            >
              {String.replace_suffix(display_url(@join_url), @code, "")}
            </span>
            <span
              id="room-code"
              class="flex items-center border-l-2 border-dashed border-jam-ink/25 pl-3 pr-4 font-display text-[1.9rem] leading-none tracking-[0.08em] text-jam-ink"
            >
              {@code}
            </span>
          </p>
        </div>
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
      class="max-w-2xl lg:max-w-[56rem] lg:p-10"
      body_class="space-y-6"
    >
      <%!-- Read from the sofa: the game's own sizes, one big row for each
           service, and the way out as a quiet link. --%>
      <div class="space-y-3">
        <h2 class="font-display text-[2.5rem] leading-none lg:text-[3.25rem]">Connect your music</h2>
        <p class="text-lg text-pretty text-base-content/75 lg:text-[1.4rem] lg:leading-snug">
          This screen plays every song the players pick. Connect a music service before you start.
        </p>
      </div>
      {music_service_list(assign(assigns, big?: true, not_now?: true))}
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
        <h2 class="text-3xl font-extrabold leading-tight tracking-[-0.02em]">
          {@active_service.question.prompt}
        </h2>
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
    {available, unconfigured} = Enum.split_with(assigns.services, &(&1.status != :unconfigured))

    assigns =
      assign(assigns,
        available: available,
        unconfigured: unconfigured,
        big?: Map.get(assigns, :big?, false),
        not_now?: Map.get(assigns, :not_now?, false)
      )

    ~H"""
    <%!-- One row a service, on the sheet itself (no panel within the
         panel), ruled off from the next. --%>
    <ul>
      <li
        :for={service <- @available}
        class={[
          "space-y-3 border-jam-cream/12 [&:not(:first-child)]:border-t",
          if(@big?, do: "py-5", else: "py-3")
        ]}
      >
        <div class="flex items-center gap-4">
          <div class="flex-1 min-w-0">
            <p class={[
              "font-bold leading-tight",
              if(@big?, do: "text-[1.75rem]", else: "text-xl")
            ]}>
              {service.name}
            </p>
            <%!-- Connected says whether this screen can play yet, in the same
                 line. --%>
            <p class={[
              if(@big?, do: "mt-1 text-[1.25rem]", else: "mt-0.5 text-lg leading-snug"),
              service_status_class(service.status)
            ]}>
              {service_status_text(service)}<span
                :if={service.status == :connected}
                class="text-jam-cream/70"
              >{if @playback_ready?,
                do: ". This screen is ready to play the music.",
                else: ". Getting this screen ready to play the music…"}</span>
            </p>
          </div>
          <a
            :if={service.connect_href && service.status != :unconfigured}
            href={service.connect_href}
            class={[
              "jam-btn",
              if(@big?, do: "text-[1.4rem]", else: "text-[1.125rem] !px-5 !py-2.5"),
              service.status == :connected && "jam-btn-ghost"
            ]}
          >
            {service_action(service.status)}
          </a>
          <button
            :if={is_nil(service.connect_href) && service.status != :unconfigured}
            type="button"
            phx-click="connect_music"
            phx-value-provider={service.id}
            class={[
              "jam-btn",
              if(@big?, do: "text-[1.4rem]", else: "text-[1.125rem] !px-5 !py-2.5"),
              service.status == :connected && "jam-btn-ghost"
            ]}
          >
            {service_action(service.status)}
          </button>
        </div>

        <div
          :if={service.question}
          id={"music-question-#{service.id}"}
          class="flex flex-wrap items-center justify-between gap-3 border-t border-jam-cream/10 pt-3"
        >
          <p class="text-lg text-base-content/80">{service.question.prompt}</p>
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
          <.icon name="hero-exclamation-triangle-solid" class="size-4 shrink-0 mt-0.5" />
          <span>{service.warning}</span>
        </p>
      </li>
    </ul>
    <%!-- What this server can't offer, in one quiet line rather than a row
         each. --%>
    <%!-- The services this server can't offer, and (in the prompt) the way
         out, on one line: no band of its own under the list. --%>
    <div
      :if={@unconfigured != [] or @not_now?}
      class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2"
    >
      <p
        :if={@unconfigured != []}
        class={["font-medium text-jam-cream/60", if(@big?, do: "text-[1.2rem]", else: "text-lg")]}
      >
        {join_names(Enum.map(@unconfigured, & &1.name))}
        {if length(@unconfigured) == 1, do: "isn’t", else: "aren’t"} set up on this server.
      </p>
      <button
        :if={@not_now?}
        type="button"
        phx-click="dismiss_music_prompt"
        class="ml-auto cursor-pointer text-base font-semibold text-jam-cream/75 underline decoration-jam-cream/30 underline-offset-4 hover:text-jam-cream lg:text-[1.3rem]"
      >
        Not now
      </button>
    </div>
    """
  end

  defp service_status_text(%{status: :connected}), do: "Connected"

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
      class="max-w-3xl max-h-[92vh] lg:max-w-[74rem]"
      body_class="space-y-5"
    >
      <%!-- The sheet's summary under its title: how long these settings
           make the game (changes save as they are made). --%>
      <div class="flex items-start justify-between gap-6">
        <div>
          <h2 class="font-display text-[2.5rem] leading-none">Settings</h2>
          <p id="settings-estimate" class="mt-2 text-[1.25rem] font-medium text-jam-cream/75">
            About <span class="font-bold text-jam-orange">{@estimate} minutes</span>
            with these settings
          </p>
        </div>
        <button
          type="button"
          phx-click="close_settings"
          aria-label="Close settings"
          class="grid size-11 cursor-pointer place-items-center rounded-md bg-jam-cream/[0.08] text-jam-cream/85 transition-colors hover:bg-jam-cream/15 hover:text-jam-cream focus-visible:bg-jam-cream/15"
        >
          <%!-- A heavier cross than the outline icon's hairline, to find
               from the sofa. --%>
          <.icon name="hero-x-mark-mini" class="size-7" />
        </button>
      </div>

      <%!-- Two columns on a wide screen, so the whole sheet is in view at
           once and the two end level: the game's times and counts, and what
           plays the music, on the left; every switch on the right, the
           rules' and the screens'. --%>
      <div class="grid gap-x-12 gap-y-6 lg:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)]">
        <div class="space-y-6">
          <section class="space-y-3">
            <h3 class="text-[1.6rem] font-bold tracking-[-0.01em]">Game</h3>

            <p :if={@view.phase != :lobby} class="text-sm text-base-content/60">
              Game settings are locked once the game starts.
            </p>

            <%!-- The time to pick and the prompts on a row, then the players
                 needed; each time with its unit written in the field. --%>
            <form phx-change="set_config" class="grid items-end gap-x-5 gap-y-1 sm:grid-cols-6">
              <fieldset disabled={@view.phase != :lobby} class="contents">
                <div class="jam-unit sm:col-span-3" data-unit="seconds">
                  <.input
                    type="number"
                    id="answer_timer_s"
                    name="answer_timer_s"
                    label="Time to pick"
                    value={@view.config.answer_timer_s}
                    min={Config.range(:answer_timer_s).first}
                    max={Config.range(:answer_timer_s).last}
                  />
                </div>
                <%!-- A count steps one at a time, its number in the scores'
                     lettering between a − and a +. --%>
                <div class="jam-stepper sm:col-span-3">
                  <.input
                    type="number"
                    id="questions_per_player"
                    name="questions_per_player"
                    label="Prompts per player"
                    value={@view.config.questions_per_player}
                    min={Config.range(:questions_per_player).first}
                    max={Config.range(:questions_per_player).last}
                  />
                  <button
                    type="button"
                    class="jam-step left-1"
                    phx-click="step_config"
                    phx-value-key="questions_per_player"
                    phx-value-to={@view.config.questions_per_player - 1}
                    disabled={
                      @view.config.questions_per_player <= Config.range(:questions_per_player).first
                    }
                    aria-label="One fewer prompt"
                  >
                    <.icon name="hero-minus-mini" class="size-5" />
                  </button>
                  <button
                    type="button"
                    class="jam-step right-1"
                    phx-click="step_config"
                    phx-value-key="questions_per_player"
                    phx-value-to={@view.config.questions_per_player + 1}
                    disabled={
                      @view.config.questions_per_player >= Config.range(:questions_per_player).last
                    }
                    aria-label="One more prompt"
                  >
                    <.icon name="hero-plus-mini" class="size-5" />
                  </button>
                </div>
                <%!-- Players needed, as the row of numbers it is. --%>
                <div class="fieldset mb-2 sm:col-span-6">
                  <%!-- (No gap under the label: the field beside it carries the
                       inline gap of its own label, and the two must sit on one
                       line.) --%>
                  <span
                    id="min-players-label"
                    class="label mb-0 w-full justify-start text-left"
                  >
                    Players needed to start
                  </span>
                  <div
                    role="radiogroup"
                    aria-labelledby="min-players-label"
                    class="flex gap-1"
                  >
                    <button
                      :for={n <- Config.range(:min_players)}
                      type="button"
                      role="radio"
                      aria-checked={to_string(n == @view.config.min_players)}
                      phx-click="step_config"
                      phx-value-key="min_players"
                      phx-value-to={n}
                      class={[
                        "h-[3.1rem] min-w-0 flex-1 cursor-pointer rounded-md text-[1.4rem] font-semibold tabular-nums transition-colors disabled:cursor-default",
                        if(n == @view.config.min_players,
                          do: "bg-jam-cream text-jam-ink",
                          else:
                            "bg-jam-cream/[0.07] text-jam-cream/80 hover:bg-jam-cream/[0.13] disabled:hover:bg-jam-cream/[0.07]"
                        )
                      ]}
                    >
                      {n}
                    </button>
                  </div>
                </div>
              </fieldset>
            </form>
          </section>

          <section class="space-y-3">
            <h3 class="text-[1.6rem] font-bold tracking-[-0.01em]">Music service</h3>
            {music_service_list(assigns)}
          </section>
        </div>
        <div class="space-y-6">
          <section class="space-y-3">
            <h3 class="text-[1.6rem] font-bold tracking-[-0.01em]">Voting</h3>
            <%!-- The vote's own times, beside each other, above its rules. --%>
            <form
              phx-change="set_config"
              id="vote-times"
              class="grid items-end gap-x-5 sm:grid-cols-2"
            >
              <fieldset disabled={@view.phase != :lobby} class="contents">
                <div class="jam-unit" data-unit="seconds">
                  <.input
                    type="number"
                    id="vote_delay_s"
                    name="vote_delay_s"
                    label="Voting opens after"
                    value={@view.config.vote_delay_s}
                    min={Config.range(:vote_delay_s).first}
                    max={Config.range(:vote_delay_s).last}
                  />
                </div>
                <div class="jam-unit" data-unit="seconds">
                  <.input
                    type="number"
                    id="vote_timer_s"
                    name="vote_timer_s"
                    label="Voting time"
                    value={@view.config.vote_timer_s}
                    min={Config.range(:vote_timer_s).first}
                    max={Config.range(:vote_timer_s).last}
                  />
                </div>
              </fieldset>
            </form>
            <%!-- The rules' switches, a row each, label left and switch
                 right, as the screens' are under them. --%>
            <form phx-change="set_config" id="rule-settings" class="grid gap-1">
              <fieldset disabled={@view.phase != :lobby} class="contents">
                <%!-- Said as the order it plays in; a theme of one style has
                     nothing to split. --%>
                <.input
                  :if={subround_label(@view.theme)}
                  type="checkbox"
                  class="toggle"
                  id="subrounds_enabled?"
                  name="subrounds_enabled?"
                  label={subround_label(@view.theme)}
                  checked={@view.config.subrounds_enabled?}
                />
                <.input
                  type="checkbox"
                  class="toggle"
                  id="allow_vote_change?"
                  name="allow_vote_change?"
                  label="Allow changing a vote"
                  checked={@view.config.allow_vote_change?}
                />
              </fieldset>
            </form>
          </section>

          <%!-- How the screens tell the game, for rooms that like it another
               way. None of these change the scoring or the timers. --%>
          <section class="space-y-3">
            <h3 class="text-[1.6rem] font-bold tracking-[-0.01em]">On the screens</h3>
            <form phx-change="set_config" id="presentation-settings" class="grid gap-1">
              <fieldset disabled={@view.phase != :lobby} class="contents">
                <.input
                  type="checkbox"
                  class="toggle"
                  id="quick_reveals?"
                  name="quick_reveals?"
                  label="Quick reveals: everything at once"
                  checked={@view.config.quick_reveals?}
                />
                <.input
                  type="checkbox"
                  class="toggle"
                  id="name_non_voters?"
                  name="name_non_voters?"
                  label="Name who didn’t vote"
                  checked={@view.config.name_non_voters?}
                />
                <.input
                  type="checkbox"
                  class="toggle"
                  id="show_places?"
                  name="show_places?"
                  label="Show everyone’s rank"
                  checked={@view.config.show_places?}
                />
                <.input
                  type="checkbox"
                  class="toggle"
                  id="final_suspense?"
                  name="final_suspense?"
                  label="Hide totals during the final round"
                  checked={@view.config.final_suspense?}
                />
              </fieldset>
            </form>
          </section>
        </div>
      </div>
    </.modal>
    """
  end

  # The sub-round switch in the order the theme plays its styles: every
  # prompt round first, then every player round (or the other way about).
  defp subround_label(%{style_sequence: styles}) do
    case Enum.uniq(styles) do
      [first, second] -> "Guess the #{style_noun(first)}s first, then the #{style_noun(second)}s"
      _ -> nil
    end
  end

  defp subround_label(_theme), do: nil

  defp style_noun(:guess_question), do: "prompt"
  defp style_noun(_style), do: "player"

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
    <%!-- Two columns that share a top and a bottom: the theme and the way in
         on the left, the room on the right. --%>
    <div class="min-h-screen grid content-center gap-12 px-12 lg:px-20 pt-28 pb-16 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)] xl:items-stretch xl:gap-24">
      <div class="flex flex-col justify-between gap-10">
        <div>
          <p class="jam-eyebrow">Tonight’s theme</p>
          <h1 class="mt-1 font-display text-[3.75rem] leading-none">{@view.theme.name}</h1>
          <p class="mt-3 max-w-2xl text-2xl font-medium leading-snug text-jam-cream/65 text-balance">
            {@view.theme.description}
          </p>
          <%!-- The one rule that changes how you pick: fooling people scores. --%>
          <ul
            id="how-to-score"
            class="mt-6 max-w-[40rem] space-y-1.5 text-[1.65rem] font-medium leading-snug text-jam-cream/85"
          >
            <li class="flex gap-4">
              <span class="w-10 shrink-0 font-display text-jam-orange">+1</span>
              <span>for each correct guess</span>
            </li>
            <li class="flex gap-4">
              <span class="w-10 shrink-0 font-display text-jam-orange">+1</span>
              <span>for each player your song fools</span>
            </li>
            <li class="flex gap-4">
              <span class="w-10 shrink-0 font-display text-jam-orange">+1</span>
              <span class="text-balance">for predicting the most common wrong guess</span>
            </li>
          </ul>
        </div>

        <%!-- The way in, as an admission ticket: the QR code on its stub, the
             room code on the rest, and the address for anyone without a
             camera. --%>
        <%!-- Never wider than its column: a gutter always separates it from
             the room beside it. --%>
        <div class="jam-lift w-fit max-w-full">
          <div class="jam-ticket flex items-stretch [--jam-notch:1.1rem]">
            <div class="shrink-0 p-5 pl-7 [&>svg]:size-56">
              <.qr_code svg={@qr_svg} />
            </div>
            <%!-- The code clear of the ticket's notch, however wide its
                 letters. --%>
            <div class="flex flex-col justify-center border-l-[3px] border-dashed border-jam-ink/20 py-6 pl-8 pr-14">
              <p class="text-2xl font-bold text-jam-ink/55">Room code</p>
              <p class="font-display text-[7rem] leading-[0.95] tracking-[0.04em] whitespace-nowrap">
                {@view.code}
              </p>
              <p class="mt-2 text-[1.4rem] font-semibold text-jam-ink/65">
                Scan to join, or go to
                <span
                  id="join-url"
                  class="block whitespace-nowrap text-2xl font-extrabold text-jam-ink"
                >
                  {display_url(@join_url)}
                </span>
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- The room: straight on the stage, no panel round it. Who's here
           starts level with the theme's heading, and Start sits right under
           the names, so no gap opens between them. --%>
      <div class="flex flex-col gap-7 xl:pt-1">
        <div class="flex items-baseline justify-between border-b-2 border-jam-cream/10 pb-3">
          <p class="jam-eyebrow">Players</p>
          <p id="player-count" class="font-display text-4xl tabular-nums">
            {@player_count}<span class="text-jam-cream/55">/{@max_players}</span>
          </p>
        </div>

        <%!-- Each player's name on a strip of tape, like the channels of a
             sound desk, large, four to a row in the seats the picking screen
             keeps them in (each tape its own width and tilt, centred in its
             seat, so the columns line up); the seats still free are dashed
             in. --%>
        <ul
          id="lobby-players"
          class="grid grid-cols-4 content-start items-center justify-items-center gap-x-4 gap-y-5"
        >
          <li
            :for={p <- @view.players}
            id={"seat-#{p.id}"}
            class={["jam-pop flex min-w-0", p.connected? || "opacity-40"]}
          >
            <%!-- In the paper tone, a step down from the ticket's white, so
                 the room code stays the thing to look at until all are in. --%>
            <.name_tape
              player_id={p.id}
              name={p.name}
              class="jam-tape-paper max-w-full px-4 py-3 text-[2.45rem]"
            />
          </li>
          <li
            :for={seat <- 1..@open_seats//1}
            id={"open-seat-#{seat}"}
            class="h-[4.4rem] w-full rounded-sm border-2 border-dashed border-jam-cream/20"
            aria-hidden="true"
          >
          </li>
        </ul>

        <div :if={@view.audience != []} class="space-y-3">
          <p class="jam-eyebrow">In the audience ({length(@view.audience)})</p>
          <div class="flex flex-wrap gap-2">
            <span :for={p <- @view.audience} class="jam-chip text-xl">{p.name}</span>
          </div>
        </div>

        <div class="mt-3 space-y-4">
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
                class="block w-full cursor-pointer text-center text-xl font-bold text-jam-cream/85 underline decoration-jam-cream/30 underline-offset-4"
              >
                Connect a music service to start
              </button>
            <% @player_count < @min_players -> %>
              <p class="text-center text-2xl font-medium text-jam-cream/65">
                {players_needed(@min_players - @player_count)}
              </p>
            <% true -> %>
          <% end %>
        </div>

        <div
          :if={@active_service && @active_service.warning}
          id="music-warning"
          class="flex items-start gap-3 rounded-xl border border-jam-orange/40 bg-jam-orange/10 px-5 py-4 text-jam-cream/90"
        >
          <.icon name="hero-exclamation-triangle-solid" class="size-6 shrink-0 text-jam-orange" />
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
    <%!-- The headline and the room's names side by side, their tops level;
         the clock under both, its bar the full width of the screen. --%>
    <div class="min-h-screen grid content-center gap-x-20 gap-y-12 px-12 lg:px-20 pt-28 pb-12 xl:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] xl:items-start">
      <div class="space-y-3">
        <p :if={@view.subround_total > 1} class="jam-eyebrow">
          Sub-round {@view.subround_index + 1} of {@view.subround_total}
        </p>
        <%!-- The last pick landing is a moment of its own (the server holds
             this screen briefly once everyone is in). --%>
        <%!-- A step down from the clock, which is what the room reads. --%>
        <h1 :if={!@all_in?} class="font-display text-[4.5rem] leading-none">Heads down</h1>
        <p :if={!@all_in?} class="text-2xl xl:text-3xl text-jam-cream/70">
          Everyone’s picking songs on their own screens.
        </p>
        <h1
          :if={@all_in?}
          id="all-in"
          class="jam-pop origin-left font-display text-[4.5rem] leading-none text-jam-mint"
        >
          {curly("Everyone’s in")}
        </h1>
        <p :if={@all_in?} class="jam-rise text-2xl xl:text-3xl text-jam-cream/70">
          Eyes up. Here comes the music.
        </p>
      </div>

      <%!-- Straight on the stage, as the lobby's names are: the tapes group
           themselves. Its heading level with the headline's. --%>
      <div :if={@view.answering} class="space-y-8 xl:pt-1.5">
        <div class="flex items-baseline justify-between">
          <p class="jam-eyebrow">Songs picked</p>
          <p id="locked-in-count" class="font-display text-4xl tabular-nums">
            {@done}<span class="text-jam-cream/55">/{length(@seats)}</span>
          </p>
        </div>

        <%!-- The lobby's names, laid out as the lobby lays them (side by
             side, as a cluster): each pencilled into its slot, and taped
             down where it was as its player locks in their songs. --%>
        <%!-- A fixed grid, four to a row: every name keeps its place as the
             tapes land, so nothing reflows when one turns into a tape; the
             check is written on the tape after the name, as the score
             strip's and the phones' are. --%>
        <ul id="answering-players" class="grid grid-cols-4 gap-x-4 gap-y-5">
          <li :for={seat <- @seats} id={"picking-#{seat.id}"} class="relative flex min-w-0">
            <.name_tape
              :if={seat.done?}
              player_id={seat.id}
              name={seat.name}
              class="jam-bump w-full gap-2 py-3 px-3 text-[2.1rem]"
            >
              <.icon
                name="hero-check-circle-solid"
                class="size-[0.75em] shrink-0 text-jam-mint-deep"
              />
            </.name_tape>
            <%!-- Pencilled into the tape's slot until their tape lands. --%>
            <div
              :if={!seat.done?}
              class={[
                "jam-tape-slot relative w-full gap-2 overflow-hidden py-3 px-3 text-[2.1rem]",
                seat.prog.total > 1 && "justify-between"
              ]}
            >
              <span class="min-w-0 truncate whitespace-nowrap">{seat.name}</span>
              <span :if={seat.prog.total > 1} class="shrink-0 text-2xl tabular-nums">
                {seat.prog.submitted}/{seat.prog.total}
              </span>
              <%!-- With several prompts each, a thin bar shows how far along. --%>
              <span
                :if={seat.prog.total > 1}
                class="absolute inset-x-0 bottom-0 h-1 bg-jam-cream/10"
                aria-hidden="true"
              >
                <span
                  class="block h-full bg-jam-pink transition-[width] duration-500"
                  style={progress_style(seat.prog)}
                ></span>
              </span>
            </div>
          </li>
        </ul>
      </div>

      <div :if={@view.answering && !@all_in?} class="space-y-1 xl:col-span-2 xl:row-start-2">
        <p class="jam-eyebrow">Time left</p>
        <p
          id="answer-countdown"
          phx-hook="Countdown"
          data-deadline={@view.answering.deadline_ms}
          class="font-display text-9xl leading-none tabular-nums text-jam-orange"
        >
        </p>
        <%!-- Its length is known: a bar, as every such countdown has. --%>
        <div
          :if={@view.answering.deadline_ms}
          id={"answer-bar-#{@view.answering.deadline_ms}"}
          phx-hook="Progress"
          phx-update="ignore"
          data-deadline={@view.answering.deadline_ms}
          data-duration={@view.config.answer_timer_s * 1000}
          class="jam-bar mt-5 h-2 w-full overflow-hidden bg-jam-cream/12"
          aria-hidden="true"
        >
          <span class="block h-full origin-left bg-jam-orange [transform:scaleX(1)]"></span>
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

  # The song takes the left, large, and never moves: its art leads. The
  # right says what it was picked for (what the room is talking about), then
  # what the room is doing right now — listen, vote, find out. The scores run
  # along the bottom.
  #
  # A video provider's player (see render/1 and player_class/2) is placed over
  # a frame this layout reserves, at the top of the left column (the layout
  # pads 6rem above), with the song's name under it.
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
        <div class="jam-round-card-text flex max-w-[66rem] flex-col items-center gap-8 text-center">
          <%!-- With a prompt, the card is the prompt: the slip the room is
               handed, large; the round is its label. Without one, the round
               is the headline. --%>
          <p :if={!@view.round.prompt} class="font-display text-8xl">
            Round {@view.round.index + 1}
            <span class="text-jam-cream/40">of {@view.round.total}</span>
          </p>
          <%!-- The round, as the slip's label (the lobby named the theme). --%>
          <p :if={@view.round.prompt} class="text-[1.75rem] font-bold text-jam-cream/70">
            Round {@view.round.index + 1} of {@view.round.total}<span :if={second_take?(@view.round)}>: another song for</span>
          </p>
          <div
            :if={@view.round.prompt}
            class="jam-paper jam-lean max-w-[52rem] px-10 pb-9 pt-10 text-jam-ink"
          >
            <%!-- Balanced lines, and never one word alone on the last. --%>
            <p class="font-display text-[4.25rem] leading-[1.1] text-balance">
              {curly(no_widow(@view.round.prompt))}
            </p>
            <%!-- The round's one clue, said here, once. --%>
            <p
              :if={@view.round.prompt_take}
              id="prompt-take"
              class="mt-5 text-[1.75rem] font-semibold text-jam-ink/75"
            >
              {take_label(@view.round.prompt_take)}
            </p>
          </div>
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
        <div class={
          [
            "flex-1 min-h-0 overflow-hidden flex flex-col gap-10 lg:flex-row lg:gap-16",
            # Centred, but never pushed up under the header when it runs tall.
            # The reveal, which runs tallest, starts at the top instead (the
            # poster's top in line with the slip's), so all its spare room
            # falls between the voters and the score strip.
            if(@view.round_state == :results,
              do: "lg:items-start",
              else: "lg:items-center-safe"
            )
          ]
        }>
          <%!-- The song is a poster: a sheet of egg-white paper laid on the
               stage, its cover printed on it and its name and artist set in
               ink, once, large enough to read from the sofa. While the room
               listens and votes it is the hero, a tall sleeve that lets the
               art lead; at the reveal it steps back to a small print and the
               answer takes the stage. --%>
          <%!-- The print's column keeps one width all round, so nothing beside
               it moves when the print steps down a size at the reveal (so the
               answer leads). --%>
          <div class="relative w-[27rem] shrink-0 p-2">
            <%!-- The same print in the same place from the first note to
                 the reveal, where it steps down a size so the answer leads. --%>
            <.poster
              song={@view.round.song}
              art_id={"art-#{@round_key}"}
              size={if @view.round_state == :results, do: :reveal, else: :wide}
              playing?={@view.round_state in [:revealing, :voting]}
            />
          </div>
          <%!-- Beside it, what the song was picked for, then what the room
               is doing right now. --%>
          <div class={[
            "min-w-0 flex-1",
            if(@view.round_state == :results, do: "space-y-4", else: "space-y-10")
          ]}>
            {prompt_band(assigns)}
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
    <figure id="round-prompt" class="space-y-4">
      <%!-- The round, and when the reveal gives way to the next song (so
           nobody is caught reading), on the stage above the slip. --%>
      <%!-- The round on the left, and the next song's clock at the
           column's right edge (the slip's), each on its own. --%>
      <figcaption class="flex items-center justify-between gap-4 text-[1.7rem] font-bold text-jam-cream/65">
        <span>Round {@view.round.index + 1} of {@view.round.total}</span>
        <span
          :if={@view.round_state == :results && @view.round.next_ms}
          id="next-up"
          class="jam-rise jam-beat-3 text-jam-cream/55"
        >
          {if @view.round.index + 1 < @view.round.total, do: "Next song in", else: "Final scores in"}
          <span
            id={"next-countdown-#{@view.round.index}"}
            phx-hook="Countdown"
            data-deadline={@view.round.next_ms}
            class="font-display text-jam-orange tabular-nums"
          ></span>
        </span>
      </figcaption>
      <%!-- The prompt was the round card's to show, large on its slip; from
           then on it is that slip, as wide as its words (it is what the room
           is talking about, but the song and the screen's headline lead),
           in the same place through to the reveal. --%>
      <div
        :if={@view.round.prompt}
        class={
          [
            "jam-paper jam-lean w-fit max-w-full text-jam-ink",
            # Smaller at the reveal, so the answer under it leads.
            if(@view.round_state == :results, do: "px-5 py-2.5", else: "px-6 py-4")
          ]
        }
      >
        <%!-- The round card gave the prompt its moment in large type; from
           the first note it is context, in the body face, so the song and
           the screen's one headline lead. --%>
        <%!-- The slip is as wide as its words, up to the column's edge (a
             strip of paper, not a banner). --%>
        <blockquote class={
          [
            # The words run the slip's full width (plain wrapping: a "pretty"
            # wrap shortens the first line), so it never shows a band of empty
            # paper beside them.
            "font-semibold leading-[1.3]",
            if(@view.round_state == :results, do: "text-[1.45rem]", else: "text-[1.75rem]")
          ]
        }>
          {no_widow(@view.round.prompt)}
        </blockquote>
      </div>
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
      <p class="mt-2 truncate text-[1.6rem] font-semibold text-jam-cream/70">
        {@view.round.song.artist}
      </p>
    </div>
    """
  end

  attr :song, :map, required: true
  attr :art_id, :string, default: nil
  attr :playing?, :boolean, default: false
  attr :size, :atom, default: :small, values: [:wide, :reveal, :small]
  attr :heading?, :boolean, default: true

  # A song as a poster: its cover printed on a sheet of paper, its name and
  # artist set in ink, the sheet a touch askew and lifted off the stage
  # (`.jam-poster` in app.css). Wide (while the song plays) the words sit
  # beside the cover, large; small (at the reveal) they sit under it. Either
  # way the song's name is the screen's heading. Keyed by round (`art_id`),
  # so a new round never shows the last one's cover while its own loads.
  defp poster(%{size: size} = assigns) when size in [:wide, :reveal] do
    ~H"""
    <figure class={[
      "jam-paper jam-poster bg-jam-cream text-jam-ink transition-[width] duration-500",
      if(@size == :reveal, do: "w-[18rem] p-3 pb-3.5", else: "w-[26rem] p-4 pb-5")
    ]}>
      <%!-- While it plays, the meter on a dark tab at the art's corner, as
           the phones have it. --%>
      <div class="relative">
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
          <.icon name="hero-musical-note-solid" class="size-1/3 text-jam-ink/40" />
        </div>
        <span
          :if={@playing?}
          class="absolute bottom-3 left-3 flex bg-jam-ink/80 px-3 py-2.5"
        >
          <.now_playing_meter class="text-[2.3rem]" />
        </span>
      </div>
      <%!-- The words sit at the foot of the sheet, as a print's do. --%>
      <figcaption class="mt-3.5 min-w-0 px-0.5">
        <h1 class={[
          "font-display leading-[1.02] line-clamp-2 text-balance break-keep [line-break:strict]",
          if(@size == :reveal, do: "text-[2.4rem]", else: "text-[3rem]")
        ]}>
          {poster_title(@song.name)}
        </h1>
        <p class={[
          "mt-1.5 truncate font-semibold text-jam-ink/65",
          if(@size == :reveal, do: "text-[1.35rem]", else: "text-[1.5rem]")
        ]}>
          {@song.artist}
        </p>
      </figcaption>
    </figure>
    """
  end

  defp poster(assigns) do
    ~H"""
    <figure class="jam-paper jam-poster jam-pop w-64 bg-jam-cream p-3 text-jam-ink">
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
        <.icon name="hero-musical-note-solid" class="size-1/3 text-jam-ink/40" />
      </div>
      <figcaption class="mt-2 space-y-1 px-1">
        <.dynamic_tag
          tag_name={if @heading?, do: "h1", else: "p"}
          class="font-display text-3xl leading-[1.05] line-clamp-2 break-keep"
        >
          {@song[:name] || @song[:song_name]}
        </.dynamic_tag>
        <p class="truncate text-xl font-semibold text-jam-ink/65">
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
    <div id="tv-listening" class="jam-rise space-y-5">
      <%!-- The song has the room: the clock is a quiet line under the
           headline, not a headline of its own; what it counts down to on
           the left, its numerals over the end of its bar, as every clock
           has them. --%>
      <div class="space-y-1">
        <p class="font-display text-[3.5rem] leading-none">Listen up</p>
        <p class="flex items-baseline justify-between gap-6 text-[1.75rem] font-medium text-jam-cream/65">
          <span>Voting opens in</span>
          <span
            id="votes-open-countdown"
            phx-hook="Countdown"
            data-deadline={@view.round.votes_open_ms}
            class="font-display text-[2.4rem] leading-none text-jam-orange tabular-nums"
          ></span>
        </p>
      </div>
      <%!-- The same wait as a line that drains, to read from across the room
           without reading a clock. The hook draws it (see Progress in
           hooks/player.js), so the page never patches it mid-fill. --%>
      <div
        id={"listen-progress-#{@round_key}"}
        phx-hook="Progress"
        phx-update="ignore"
        data-deadline={@view.round.votes_open_ms}
        data-duration={@view.config.vote_delay_s * 1000}
        class="jam-bar h-2 overflow-hidden bg-jam-cream/12"
        aria-hidden="true"
      >
        <span class="block h-full origin-left bg-jam-orange [transform:scaleX(1)]"></span>
      </div>
    </div>
    """
  end

  # Says who is in, never what they chose. Everyone has something to lock in,
  # the picker included (their guess at who the room will blame), so the names
  # give nothing away.
  defp voting(assigns) do
    received = assigns.view.round.votes_received
    expected = assigns.view.round.eligible_voters
    all_in? = assigns.view.round.all_in?

    # The players the round waits for (connected, the picker too) not yet in.
    # The audience isn't called out: its chips go quiet on their own.
    waiting =
      for p <- assigns.view.players,
          p.connected?,
          p.id not in assigns.view.round.voters,
          do: p.name

    audience = Enum.filter(assigns.view.audience, & &1.connected?)

    assigns =
      assign(assigns,
        received: received,
        expected: expected,
        all_in?: all_in?,
        waiting: waiting,
        audience_total: length(audience),
        audience_in: Enum.count(audience, &(&1.id in assigns.view.round.voters))
      )

    ~H"""
    <div id="tv-voting" class="space-y-5">
      <%!-- Once everyone has voted there is nobody left to tell to. --%>
      <div
        :if={@all_in?}
        id="tv-all-in"
        class="jam-bump space-y-4 text-jam-cream"
      >
        <div>
          <div>
            <%!-- This countdown is the reveal's held breath: when it runs
                 out the name is on screen, with no second wait after it.
                 Where votes can still change, it is the last chance to, as
                 the phones say too. --%>
            <p class="font-display text-[3.5rem] leading-none text-jam-mint">
              {if @view.config.allow_vote_change?, do: "All in", else: "All votes in"}
            </p>
            <p
              :if={@view.config.allow_vote_change?}
              class="mt-2 text-3xl font-medium text-jam-cream/80"
            >
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
      <%!-- A headline, not a box: the call to the room, in pink, turning
           orange with the clock in its last seconds. --%>
      <div
        :if={!@all_in?}
        id="tv-vote-now"
        class="jam-pop group text-jam-cream"
      >
        <p class="whitespace-nowrap font-display text-[3.5rem] leading-none text-jam-pink transition-colors group-has-[[data-urgent]]:text-jam-orange">
          Vote now
        </p>
        <%!-- Where to vote, as the one instruction. --%>
        <p class="mt-3 text-[1.85rem] font-semibold text-jam-cream/80">
          On your own screen.
        </p>
      </div>
      <%!-- The last few still choosing, by name: who the room is waiting
           on, said outright (the chips below are the whole roll). --%>
      <p
        :if={!@all_in? and @waiting != [] and length(@waiting) <= 3}
        id="waiting-for"
        class="text-[1.75rem] font-bold text-jam-cream"
      >
        {if @view.config[:name_non_voters?] == false,
          do: "Waiting for #{length(@waiting)} more",
          else: "Waiting for #{join_names(@waiting)}"}
      </p>

      <%!-- How many are in, said once: who they are is the score strip's to
           show (a tape lands on each seat as its player locks in, the
           picker's too, so it says nothing about whose song this is). The
           audience, who have no seat there, are counted here. Never what
           anyone chose. --%>
      <%!-- The count, as the song-picking screen keeps it. --%>
      <div class="jam-pop flex min-h-[4rem] items-end">
        <p
          id="vote-progress"
          class="flex items-baseline gap-3 text-[1.75rem] font-semibold text-jam-cream/70"
        >
          <span class="font-display text-[3rem] leading-none text-jam-cream tabular-nums">
            {@received}<span class="text-jam-cream/55">/{@expected}</span>
          </span>
          locked in
          <span :if={@audience_total > 0} id="audience-progress" class="ml-3 text-[1.5rem]">
            (audience {@audience_in}/{@audience_total})
          </span>
        </p>
      </div>
      <%!-- The clock, as the phones show it: before it runs, what starts it
           and its length in grey over a dashed slot (as everything that
           hasn't happened yet is drawn); once it runs, the time left over a
           bar that starts full and drains. The words on the left, the
           numerals over the bar's end. Nothing moves when it starts. --%>
      <div :if={!@all_in?} id="tv-vote-clock" class="jam-pop space-y-3">
        <.tv_timer
          :if={@view.round.deadline_ms}
          id="vote-countdown"
          label="Time left"
          deadline={@view.round.deadline_ms}
          class="justify-between"
        />
        <div
          :if={!@view.round.deadline_ms}
          id="clock-note"
          class="flex items-baseline justify-between gap-4"
        >
          <p class="text-[1.75rem] font-semibold text-jam-cream/70">
            Starts when most players lock in
          </p>
          <p class="font-display text-[3.5rem] leading-none tabular-nums text-jam-cream/60">
            {clock_length(@view.config.vote_timer_s)}
          </p>
        </div>
        <div
          :if={@view.round.deadline_ms}
          id={"vote-bar-#{@view.round.deadline_ms}"}
          phx-hook="Progress"
          phx-update="ignore"
          data-deadline={@view.round.deadline_ms}
          data-duration={@view.config.vote_timer_s * 1000}
          class="jam-bar h-2 overflow-hidden bg-jam-cream/12"
          aria-hidden="true"
        >
          <span class="block h-full origin-left bg-jam-orange [transform:scaleX(1)]"></span>
        </div>
        <div
          :if={!@view.round.deadline_ms}
          class="jam-bar h-2 border-[0.15rem] border-dashed border-jam-cream/40"
          aria-hidden="true"
        >
        </div>
      </div>
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
    <div class={["flex items-baseline gap-4", @class]}>
      <p class="text-[1.75rem] font-semibold text-jam-cream/70">{@label}</p>
      <p
        id={@id}
        phx-hook="Countdown"
        data-deadline={@deadline}
        class="font-display text-[3.5rem] leading-none tabular-nums text-jam-orange"
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
          <p class="jam-eyebrow !text-jam-mint">Called it, +1 each</p>
          <div class="flex flex-wrap gap-2.5">
            <span :for={name <- @breakdown.right} class="jam-chip text-3xl">{name}</span>
          </div>
        </div>

        <div :if={@breakdown.wrong != []} id="fooled" class="space-y-3">
          <p class="jam-eyebrow !text-jam-orange">
            Fooled<span :if={@breakdown.fool_points > 0}>, +{@breakdown.fool_points} to {@submitter_name}</span>
          </p>
          <div class="flex flex-wrap gap-2.5">
            <span :for={name <- @breakdown.wrong} class="jam-chip text-3xl">{name}</span>
          </div>
        </div>

        <div :if={@breakdown.missing != []} id="no-vote" class="space-y-3">
          <p class="jam-eyebrow">{length(@breakdown.missing)} didn’t vote</p>
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
    <div id="tv-results" class="space-y-5">
      <%!-- One column, read down in the reveal's beats: the name, then what
           it was worth to the picker right under it, then who said whom. --%>
      <div class="flex flex-col items-start gap-y-3">
        <div>
          <p class="jam-rise text-[1.6rem] font-bold text-jam-cream/65">
            {if timed_out?(@view.round), do: "Time’s up. It was…", else: "It was…"}
          </p>
          <%!-- The name, underlined in marker once it has landed. --%>
          <p class={[
            "jam-pop jam-beat-1 relative w-fit origin-left whitespace-nowrap pb-[0.14em] font-display leading-none text-jam-pink",
            reveal_name_size(@submitter_name)
          ]}>
            {@submitter_name}
            <.marker_stroke
              kind={:underline}
              class="jam-stroke-draw jam-stroke-after-name absolute bottom-0 left-[-2%] h-[0.12em] w-[104%] [--jam-stroke-w:0.32rem]"
            />
          </p>
        </div>

        <%!-- What it was worth to the picker, as aligned rows under the name
             (each sticker kept with its words, so neither reads as one
             run-on line): the fooling, then the prediction, each led by its
             points on an orange sticker. Set close, so the voters under it
             keep their room above the score strip. --%>
        <%!-- Set a step quieter than the name: the body face at 500–600, so
             the answer stays the loudest thing on the screen. --%>
        <div class="jam-rise jam-beat-2 space-y-2 text-[1.5rem] font-medium leading-snug">
          <p id="reveal-summary" class="flex items-center gap-4 font-semibold text-jam-cream">
            <span
              :if={@summary.points}
              class="jam-sticker w-[3.3rem] shrink-0 bg-jam-orange py-0.5 text-center font-display text-[1.45rem] leading-tight text-jam-ink"
            >
              {@summary.points}
            </span>
            <span>{@summary.text}</span>
          </p>
          <%!-- The picker's prediction, right or not, in the same form. --%>
          <.forecast :if={@forecast_line} line={@forecast_line} pad?={!!@summary.points} />
        </div>
      </div>

      <%!-- Who said whom, straight on the stage (the tapes group
           themselves): a group for each player named, the right one first
           and on mint tape, under a small label each. --%>
      <div class="jam-rise jam-beat-2c">
        <%!-- Side by side (up to three groups; a scattered room wraps), each
             group as wide as its share, its names wrapping inside it. --%>
        <ul
          :if={@guesses != []}
          id="room-said"
          class={[
            "flex w-full gap-y-5",
            if(length(@guesses) > 3, do: "flex-wrap", else: "flex-nowrap")
          ]}
        >
          <li
            :for={guess <- @guesses}
            id={"said-#{guess.id}"}
            class="max-w-full flex-[0_1_auto] pr-16"
          >
            <%!-- The group's heading is a count, in the body face: the names
                 under it are what the room reads. --%>
            <p class={[
              "flex items-baseline gap-3 font-bold leading-tight tracking-[-0.01em]",
              @guess_size.said,
              if(guess.none?, do: "text-jam-cream/60", else: "text-jam-cream/85")
            ]}>
              <span class="whitespace-nowrap">{card_heading(guess)}</span>
            </p>
            <p
              :if={guess.none? and guess.voters != []}
              class={[
                "mt-2 line-clamp-2 font-bold leading-tight text-jam-cream/60",
                @guess_size.voters
              ]}
            >
              {Enum.join(guess.voters, ", ")}
            </p>
            <%!-- In balanced rows: six names as two rows of three, not five
                 and one. --%>
            <%!-- Who said it, every voter on their tape (a pencilled name
                 only ever means "not in yet"); those who called it on mint
                 tape, as mint is for right. --%>
            <%!-- Each tape its own width, lying its own way, in rows that
                 flow (no columns, so a short name leaves no hole). --%>
            <div :if={!guess.none?} class="mt-3 flex w-fit flex-col items-start gap-y-3">
              <div
                :for={row <- tape_rows(guess.voters, length(@guesses))}
                class="flex items-center gap-x-3"
              >
                <.name_tape
                  :for={voter <- row}
                  player_id={voter.id}
                  name={voter.name}
                  class={["max-w-full", guess.right? && "jam-tape-mint", @guess_size.voters]}
                />
              </div>
            </div>
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

    # While the vote is open the strip is also who is in: a player's tape
    # lands on their seat when they lock in (the picker's too, so it gives
    # nothing away), and until then their name is only pencilled in.
    voting? = view.round_state == :voting

    assigns =
      assign(assigns,
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
            |> Map.merge(lock_in(view, p, voting?))
          end
      )

    ~H"""
    <ol
      id="score-strip"
      aria-label="Scores"
      class={[
        "jam-panel relative flex h-24 shrink-0 justify-center gap-1.5 p-1.5",
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
        This round. Final scores next.
      </li>
      <li
        :for={cell <- @cells}
        id={"strip-#{cell.id}"}
        data-in={cell.in? && "true"}
        class="grid min-w-0 flex-1"
      >
        <%= if cell.was != cell.now do %>
          <.seat
            id={"was-#{cell.id}-#{@view.round.index}"}
            player_id={cell.id}
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
            player_id={cell.id}
            name={cell.name}
            seat={cell.now}
            name_class={@name_class}
            away?={cell.away?}
            gain={cell.gain}
            class={["jam-beat-2c", if(cell.gain > 0, do: "jam-pop", else: "jam-rise")]}
          />
        <% else %>
          <.seat
            id={"now-#{cell.id}"}
            player_id={cell.id}
            name={cell.name}
            seat={cell.now}
            name_class={@name_class}
            away?={cell.away?}
            in?={cell.in?}
            locked?={cell.locked?}
          />
        <% end %>
      </li>
    </ol>
    """
  end

  # Whether a seat's tape is down (it is, unless the vote is open and they
  # haven't locked in) and whether it wears the vote's mint check.
  defp lock_in(view, player, true = _voting?) do
    locked? = player.connected? and player.id in view.round.voters
    %{in?: locked?, locked?: locked?}
  end

  defp lock_in(_view, _player, false = _voting?), do: %{in?: true, locked?: false}

  # One size for every name in the strip: smaller for all when one is long,
  # and on the last reveal, whose strip makes room for its label.
  defp strip_name_class(_view, true = _final_reveal?), do: "text-[1.55rem]"

  # Every place shown takes a row of its own: the names a size down to make
  # it room.
  defp strip_name_class(%{config: %{show_places?: true}}, false), do: "text-[1.4rem]"

  defp strip_name_class(%{players: players}, false) do
    if length(players) > 5 and Enum.any?(players, &(String.length(&1.name) > 11)),
      do: "text-[1.5rem]",
      else: "text-[1.7rem]"
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
  attr :player_id, :string, required: true
  attr :name, :string, required: true
  attr :seat, :map, required: true
  attr :in?, :boolean, default: true, doc: "locked in (or not voting): their tape is down"
  attr :locked?, :boolean, default: false, doc: "locked in while the vote is open: a mint check"
  attr :gain, :integer, default: 0
  attr :name_class, :string, default: "text-[1.7rem]"
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
        "relative flex h-full min-w-0 flex-col items-center justify-center gap-1.5 rounded-xl px-1.5 [grid-area:1/1]",
        @seat.leader? && "bg-jam-cream text-jam-ink",
        @class
      ]}
      {@rest}
    >
      <%!-- Who leads wears the prize's orange tape (no label of its own); a
           phone that has dropped out says so above its seat, so the room
           can see who to help back in. --%>
      <span
        :if={@away?}
        class="absolute -top-5 left-1/2 -translate-x-1/2 rounded-full bg-jam-orange px-3.5 py-1 text-lg font-extrabold leading-none text-jam-ink"
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
      <%!-- The name on its tape once it's down; pencilled into the tape's
           slot until then. --%>
      <span class={["relative flex max-w-full items-center justify-center leading-none", @name_class]}>
        <.name_tape
          :if={@in?}
          player_id={@player_id}
          name={@name}
          class={[
            "jam-bump max-w-full",
            if(@seat.ring? and @tag? and !@away?, do: "jam-tape-orange", else: "jam-tape-paper"),
            @locked? && "gap-1.5",
            @away? && "opacity-50"
          ]}
        >
          <.icon
            :if={@locked?}
            name="hero-check-circle-solid"
            class="size-[0.95em] shrink-0 text-jam-mint-deep"
          />
        </.name_tape>
        <span :if={!@in?} class="jam-tape-slot max-w-full">
          <span class="min-w-0 truncate">{@name}</span>
        </span>
        <%!-- What this round added: a small orange sticker slapped on the
             tape's corner, as a phone's result wears its points, away from
             the total under the name, so "1" and "+1" never read as a sum. --%>
        <span
          :if={@seat.score && @gain > 0}
          class="jam-sticker absolute -right-4 -top-4 z-10 rotate-[3deg] bg-jam-orange px-[0.4rem] py-[0.2rem] font-display text-[1.3rem] leading-none text-jam-ink"
        >
          +{@gain}
        </span>
      </span>
      <%!-- A seat with no total (the last reveal) says only what it won. --%>
      <span
        :if={is_nil(@seat.score)}
        class={[
          "font-display text-[2.2rem] leading-none tabular-nums",
          if(@gain == 0, do: "text-jam-cream/50", else: "text-jam-orange")
        ]}
      >
        {if @gain > 0, do: "+#{@gain}", else: "–"}
      </span>
      <%!-- The total, centred under the name, alone (what this round added
           is on the tape's corner). --%>
      <span :if={@seat.score} class={["relative flex justify-center", @away? && "opacity-50"]}>
        <span class={[
          "font-display leading-none tabular-nums",
          if(@seat[:rank], do: "text-[2rem]", else: "text-[2.2rem]"),
          cond do
            @seat.leader? -> "text-jam-ink"
            @seat.score > 0 -> "text-jam-orange"
            true -> "text-jam-cream/50"
          end
        ]}>
          {@seat.score}
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
         then third, then a held breath with the top two face down), and the
         winner arrives last, the top two turned over and the headline at once
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
      <%!-- The cover's tint stays on through the winner's moment, so the
           room's light doesn't change as the card comes and goes. --%>
      <div :if={@art_url} class="jam-ambient jam-ambient-soft">
        <img src={@art_url} alt="" />
      </div>
      <div class={[
        "flex items-center",
        if(length(@winner_songs) == 1,
          do: "gap-20 text-left",
          else: "flex-col-reverse gap-12 text-center"
        )
      ]}>
        <%!-- The winner's song beside their name (in a tie, the names first
             and each winner's song, smaller, under them): their best bluff,
             when the night's best was theirs, and it says so. --%>
        <div
          :if={@winner_songs != []}
          class={[
            "flex shrink-0 items-start gap-10",
            length(@winner_songs) > 1 && "[&_figure]:!w-52"
          ]}
        >
          <div :for={song <- @winner_songs} class="relative flex flex-col items-center">
            <.poster song={song} heading?={false} />
            <%!-- The night's best bluff wears a sticker saying so. --%>
            <p
              :if={song.caption}
              class="jam-tape jam-tape-orange jam-tilt-4 absolute -right-10 -top-5 whitespace-nowrap text-[1.6rem]"
            >
              {song.caption}
            </p>
            <%!-- Tied winners' songs each say whose they are, on the prize's
                 orange tape, taped over the print's foot. --%>
            <.name_tape
              :if={length(@winner_songs) > 1}
              player_id={song.owner_id}
              name={song.owner}
              class="jam-tape-orange relative z-10 -mt-6 max-w-52 text-[1.85rem]"
            />
          </div>
        </div>
        <div class="min-w-0 space-y-4">
          <%!-- The winner's name in egg white, with a crown drawn on its
               first letter in orange marker, worn: sitting on the letter's
               top, overlapping it a little. The orange is the prize's (the
               crown, the tapes) and the points', so the name stands clear of
               it. --%>
          <%!-- A shared win wears one crown, over the middle of the names,
               so neither reads as the winner. --%>
          <p class={[
            "jam-pop jam-finale-win relative mt-[0.3em] w-fit font-display leading-none text-balance text-jam-cream",
            length(@winner_songs) > 1 && "mx-auto",
            winner_card_size(@winners, @board)
          ]}>
            <.marker_stroke
              :if={winner_verb(@winners, @board)}
              kind={:crown}
              class={[
                "absolute -top-[0.38em] h-[0.52em] w-[0.64em] text-jam-orange [--jam-stroke-w:0.6rem]",
                if(match?([_], @winners),
                  do: "left-[0.01em] -rotate-[9deg]",
                  else: "left-1/2 -translate-x-1/2 -rotate-[4deg]"
                )
              ]}
            />
            <.winner_names winners={@winners} board={@board} />
          </p>
          <%!-- What they did and how, a step down from the names: the
               points in orange, as every point is; the margin quieter under
               them. --%>
          <p class="text-[3rem] font-semibold leading-tight text-jam-cream">
            <.winner_points_line winners={@winners} verb={winner_verb(@winners, @board)} />
            <span
              :if={winner_margin(@winners, @board)}
              class="mt-1 block text-[2.4rem] font-semibold text-jam-cream/65"
            >
              {winner_margin(@winners, @board)}
            </span>
          </p>
        </div>
      </div>
    </div>
    <div class="min-h-screen flex flex-col justify-center gap-7 px-12 lg:px-20 pt-24 pb-10">
      <div class="grid gap-x-16 gap-y-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,32rem)] lg:items-stretch">
        <%!-- One left edge for the heading and the awards under it; its top
             level with the table's label, and its buttons' foot with the
             table's. --%>
        <div class="flex flex-col gap-8">
          <div>
            <div class="min-w-0 space-y-2">
              <%!-- The winner's line takes only its own height: what holds its
                   place until they are named lies over the left half of the
                   screen, out of the flow and level with the table's middle,
                   so the lines under the name sit close to it. --%>
              <div class="relative grid items-center">
                <%!-- What holds the winner's place until they are named. --%>
                <div
                  :if={@build?}
                  id="winner-wait"
                  class="jam-out jam-finale-wait pointer-events-none fixed inset-y-0 left-0 flex w-1/2 items-center px-12 lg:px-20"
                  aria-hidden="true"
                >
                  <%!-- The only unknown on screen is the table's orange "?"
                       tape: the headline says what it is waiting for. --%>
                  <p class="font-display text-[6.5rem] leading-[1.02] text-balance text-jam-cream">
                    And the winner is…
                  </p>
                </div>
                <h1
                  id="winner"
                  class={[
                    "relative font-display leading-none text-balance text-jam-cream [grid-area:1/1]",
                    winner_size_class(length(@winners)),
                    @build? && "jam-pop jam-finale-win origin-left"
                  ]}
                >
                  <%!-- The crown the winner wore on their card, still on. --%>
                  <.marker_stroke
                    :if={length(@winners) == 1}
                    kind={:crown}
                    class="absolute left-[0.01em] -top-[0.38em] h-[0.52em] w-[0.64em] -rotate-[9deg] text-jam-orange [--jam-stroke-w:0.4rem]"
                  />
                  <.winner_names winners={@winners} board={@board} />
                </h1>
              </div>
              <%!-- How it was won: the score, and how close it was. --%>
              <p
                :if={@winners != []}
                id="winner-margin"
                class={[
                  "mt-1 text-3xl font-semibold text-jam-cream/85",
                  @build? && "jam-rise jam-finale-after-1"
                ]}
              >
                <span class="block">
                  <.winner_points_line winners={@winners} verb={winner_verb(@winners, @board)} />
                </span>
                <span
                  :if={winner_margin(@winners, @board)}
                  class="block whitespace-nowrap text-jam-cream/60"
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
            class={["space-y-7 pt-6", @build? && "jam-rise jam-finale-after-2"]}
          >
            <%!-- Each award a slip of paper, the slips one width so they
                 stack as a pair, lying opposite ways: its title on orange
                 tape, what it was for, and the song it was won with on a
                 row of its own. One
                 player's two awards share a slip with their name on its
                 tape, a row each, each award named at its row's head. --%>
            <div
              :for={{title, rows, song} <- @awards}
              class="jam-paper relative w-[30rem] max-w-full px-6 pb-6 pt-7 text-jam-ink odd:!rotate-[-1.5deg] even:!rotate-[1.3deg]"
            >
              <dt
                :if={!Enum.any?(rows, &elem(&1, 0))}
                class="jam-tape jam-tape-orange absolute -top-4 left-5 whitespace-nowrap text-[1.4rem]"
              >
                {title}
              </dt>
              <p
                :if={Enum.any?(rows, &elem(&1, 0))}
                class="jam-tape jam-tape-orange absolute -top-4 left-5 whitespace-nowrap text-[1.4rem]"
              >
                {title}
              </p>
              <div
                :for={{label, text} <- rows}
                class="flex flex-wrap items-baseline gap-x-2 text-[1.65rem] leading-snug [&+&]:mt-1"
              >
                <dt :if={label} class="font-bold after:content-[':']">{label}</dt>
                <dd class="font-medium text-balance">{text}</dd>
              </div>
              <dd :if={song} class="mt-2.5 flex items-center gap-3">
                <img
                  :if={song[:album_art_url]}
                  src={song.album_art_url}
                  alt=""
                  class="size-14 shrink-0 rounded-sm object-cover"
                />
                <span class="min-w-0 text-[1.5rem] font-bold leading-tight text-jam-ink/75 line-clamp-2">
                  {song.song_name}
                </span>
              </dd>
            </div>
          </dl>

          <%!-- The host's buttons, in the left column under what the game is
               remembered for (never under the table). --%>
          <div class={["space-y-3 lg:mt-auto", @build? && "jam-rise jam-finale-after-3"]}>
            <div class="flex flex-wrap items-center gap-3">
              <button phx-click="play_again" class="jam-btn min-w-[12rem] text-[1.4rem]">
                Play again
              </button>
              <button
                :if={@playlist != []}
                id="toggle-playlist"
                type="button"
                phx-click="toggle_playlist"
                class="jam-btn jam-btn-ghost text-[1.4rem]"
              >
                {if @playlist_open?, do: "Back to the scores", else: "Tonight’s playlist"}
              </button>
              <%!-- Leaving is the quiet one: a text button kept with the
                   others, a step apart, not adrift at the column's edge. --%>
              <button
                id="exit-game"
                type="button"
                phx-click="exit_game"
                data-confirm="End the game for everyone?"
                class="ml-3 cursor-pointer px-2 text-[1.4rem] font-bold text-jam-cream/70 underline decoration-jam-cream/30 underline-offset-4 transition-colors hover:text-jam-cream"
              >
                Exit game
              </button>
            </div>
          </div>
        </div>

        <div class="space-y-6">
          <%!-- The night's setlist, best first, the way every phone lists it
               too: place, name on its tape, score; first place on orange
               prize tape, a row taller. --%>
          <%!-- What the table is, on the table, as the phones have it (a tie
               is the headline's to say: "… share the win"). --%>
          <p :if={!@playlist_open?} class="jam-eyebrow -mb-3 px-1 pb-3">Final scores</p>
          <ol :if={!@playlist_open?} id="final-scores" class="jam-panel px-3 py-3">
            <li :for={row <- @board} class="grid">
              <%!-- The top two are kept face down while the rest fill in, so
                   the winner is never given away by who is left: a final two,
                   turned over together as the winner is named. --%>
              <div
                :if={@build? and @crowned? and row.rank <= 2}
                class={[
                  "jam-out jam-finale-wait flex items-center gap-5 px-4 [grid-area:1/1]",
                  final_row_size(@board, row.rank == 1)
                ]}
                aria-hidden="true"
              >
                <span class={[
                  "flex w-[7.5rem] shrink-0 items-baseline gap-2 self-stretch text-[1.6rem] font-semibold leading-none",
                  row.tied? && tie_bracket(@board, row),
                  if(row.rank == 1, do: "text-jam-orange", else: "text-jam-cream/60")
                ]}>
                  <span class={[
                    "flex items-baseline gap-2 self-center",
                    (row.tied? and tie_part(@board, row) != :first) && "sr-only"
                  ]}>
                    {Standings.ordinal(row.rank)}
                    <span :if={row.tied?} class="text-[1.4rem]">tied</span>
                  </span>
                </span>
                <%!-- A blank the width of a name, turned over with the rest. --%>
                <span class={[
                  "jam-tape min-w-[8rem] justify-center px-6",
                  if(row.rank == 1, do: "jam-tape-orange jam-tilt-1", else: "jam-tilt-3")
                ]}>
                  ?
                </span>
              </div>
              <div class={[
                "flex items-center justify-between gap-4 px-4 [grid-area:1/1]",
                final_row_size(@board, row.rank == 1),
                @build? && @crowned? && row.rank <= 2 && "jam-pop jam-finale-win",
                @build? && !(@crowned? and row.rank <= 2) &&
                  "jam-rise #{count_class(row.rank, @count_steps)}"
              ]}>
                <span class="flex min-w-0 shrink items-center gap-5">
                  <%!-- A shared place is said once, at the head of its run,
                       with a line down the run's rows bracketing them as
                       one place (no order among them). --%>
                  <span class={[
                    "flex w-[7.5rem] shrink-0 items-baseline gap-2 self-stretch text-[1.6rem] font-semibold leading-none tabular-nums",
                    row.tied? && tie_bracket(@board, row),
                    if(row.rank == 1, do: "text-jam-orange", else: "text-jam-cream/60")
                  ]}>
                    <%!-- (Said on every row for a screen reader; shown at the head
                         of the run only.) --%>
                    <span class={[
                      "flex items-baseline gap-2 self-center",
                      (row.tied? and tie_part(@board, row) != :first) && "sr-only"
                    ]}>
                      {Standings.ordinal(row.rank)}
                      <span :if={row.tied?} class="font-body text-[1.4rem] font-semibold">
                        tied
                      </span>
                    </span>
                  </span>
                  <.name_tape
                    player_id={row.id}
                    name={row.name}
                    class={[
                      "max-w-[22rem]",
                      (@crowned? and row.rank == 1) && "jam-tape-orange"
                    ]}
                  />
                </span>
                <%!-- Points are orange (none, quieter). --%>
                <span class={[
                  "shrink-0 text-right font-display tabular-nums",
                  if(row.score > 0, do: "text-jam-orange", else: "text-jam-cream/50")
                ]}>
                  {row.score}
                </span>
              </div>
            </li>
          </ol>

          <%!-- What the room takes home, on the host's say-so: the night's songs,
               and whose they were. --%>
          <div :if={@playlist_open?} id="playlist" class="jam-rise space-y-4">
            <p class="jam-eyebrow">Tonight’s playlist</p>
            <ol class="space-y-3 text-3xl">
              <li :for={song <- @playlist} class="flex items-baseline justify-between gap-8">
                <span class="min-w-0 truncate">
                  <span class="font-display">{song.song_name}</span>
                  <span :if={song.artist} class="ml-2 text-2xl text-jam-cream/60">{song.artist}</span>
                </span>
                <span class="shrink-0 font-bold text-jam-cream/60">{song.picked_by}</span>
              </li>
            </ol>
            <p :if={@playlist_more > 0} class="text-2xl text-jam-cream/60">
              and {@playlist_more} more
            </p>
          </div>

          <%!-- The audience's own table, under the players', a row each. --%>
          <div
            :if={@audience_board != []}
            id="audience-scores"
            class={["space-y-2", @build? && "jam-rise jam-finale-after-2"]}
          >
            <p class="jam-eyebrow">Audience, by correct guesses</p>
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

        song |> Map.put(:owner, winner.name) |> Map.put(:owner_id, winner.id)
    end
  end

  defp bluff_song(_covered, nil), do: nil

  defp bluff_song(covered, {song_name, fooled}) do
    case Enum.find(covered, &(&1.song_name == song_name)) do
      nil -> nil
      song -> Map.put(song, :caption, "Best bluff: fooled #{fooled}")
    end
  end

  defp covered_song?(song, player_id) do
    url = Map.get(song, :album_art_url)
    song.player_id == player_id and is_binary(url) and url != ""
  end

  # The night's best bluff, if it was this player's and the award is given
  # (`Awards.given?/1`: the awards beside the poster say so too).
  defp best_bluff_of(
         %{awards: %{best_bluff: %{fooled: fooled, bluffs: bluffs} = award}},
         player_id
       ) do
    with true <- Awards.given?(award),
         %{song_name: song_name} <- Enum.find(bluffs, &(&1.player_id == player_id)) do
      {song_name, fooled}
    else
      _ -> nil
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

  defp take_label(%{nth: 1, of: of}), do: "#{of} songs picked for this prompt"
  defp take_label(%{nth: 2, of: 2}), do: "The other song picked for this prompt"
  defp take_label(%{nth: nth, of: of}), do: "Song #{nth} of #{of} picked for this prompt"

  # The answer as large as it can be and still sit on one line: names run up
  # to 24 characters.
  defp reveal_name_size(name) do
    case String.length(name) do
      n when n <= 8 -> "text-[9.5rem]"
      n when n <= 12 -> "text-[7.5rem]"
      n when n <= 17 -> "text-[6rem]"
      _ -> "text-[4.25rem]"
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
        {"Predicted #{choice_name(view, round, choice)}, but nobody was fooled", false}

      took ->
        {prediction(choice_name(view, round, choice), took, right?, round.style), right?}
    end
  end

  defp forecast_line(_view), do: nil

  # One word for the mechanic everywhere, blame: whoever most of the wrong
  # guesses went to "took the blame" (true however few were fooled; never
  # "the room"), and one for the picker's part in it, predict ("called it"
  # is the right guessers'). A miss is said as clearly
  # as a hit, with no points to it.
  defp prediction(guess, _took, true, _style),
    do: "Predicted the blame on #{guess}"

  defp prediction(guess, took, false, _style),
    do: "Predicted #{guess}, but #{join_names(took)} took the blame"

  attr :line, :any, required: true
  attr :class, :any, default: nil
  attr :pad?, :boolean, default: true, doc: "the line above leads with a sticker to align with"

  # The prediction's line on the reveal, led by what it was worth (+1 or +0)
  # like the picker's own line above it.
  defp forecast(assigns) do
    ~H"""
    <p
      id="forecast"
      class={[
        "flex items-center gap-4",
        if(elem(@line, 1), do: "text-jam-cream", else: "text-jam-cream/70"),
        @class
      ]}
    >
      <span
        :if={elem(@line, 1)}
        class="jam-sticker w-[3.3rem] shrink-0 bg-jam-orange py-0.5 text-center font-display text-[1.45rem] leading-tight text-jam-ink"
      >
        +1
      </span>
      <%!-- A miss wins nothing, so it has no sticker: only its place, so
           the lines stay aligned (and not even that when the line above has
           no sticker either). --%>
      <span :if={!elem(@line, 1) and @pad?} class="w-[3.3rem] shrink-0" aria-hidden="true"></span>
      <span>{elem(@line, 0)}.</span>
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
  defp card_heading(%{none?: true, count: count}), do: "#{count} didn’t vote"
  defp card_heading(guess), do: "#{length(guess.voters)} said #{guess.name}"

  # How large the room's guesses are set: as large as the number of cards
  # leaves room for. A room that agreed (one to three suspects, one row) gets
  # them at a size to read from the sofa; a room that scattered needs two rows,
  # so each card is smaller and the reveal still fits above the scores.
  defp guess_size(count) when count <= 2,
    do: %{card: "px-6 pb-5 pt-4", said: "text-[1.85rem]", voters: "text-[1.65rem]"}

  defp guess_size(3),
    do: %{card: "px-6 pb-5 pt-4", said: "text-[1.7rem]", voters: "text-[1.35rem]"}

  defp guess_size(_count),
    do: %{card: "px-5 pb-4 pt-3", said: "text-[1.5rem]", voters: "text-[1.15rem]"}

  # A group's name tapes in rows that come out even (six as two rows of
  # three, not five and one). A group on its own has the panel's width, so up
  # to seven names make one row.
  defp tape_rows(voters, 1 = _groups) when length(voters) <= 7, do: [voters]
  defp tape_rows(voters, _groups) when length(voters) <= 3, do: [voters]
  defp tape_rows(voters, _groups) when length(voters) == 4, do: Enum.chunk_every(voters, 2)
  defp tape_rows(voters, _groups) when length(voters) <= 6, do: Enum.chunk_every(voters, 3)
  defp tape_rows(voters, _groups), do: Enum.chunk_every(voters, 4)

  # A guess-who round's votes by suspect: each player somebody named, with who
  # named them. The right answer always comes first, so the eye knows where to
  # find it; then the most-named (in seat order between equals).
  defp guesses(%{round: round} = view) do
    choices = Map.new(round.votes || [], &{&1.voter_id, &1.choice})
    voters = Enum.filter(view.players ++ view.audience, &Map.has_key?(choices, &1.id))

    named =
      for suspect <- view.players,
          named_by = for(v <- voters, choices[v.id] == suspect.id, do: %{id: v.id, name: v.name}),
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
    do: %{points: plus_points(points), text: "Fooled #{join_names(wrong)}."}

  defp reveal_summary(%{wrong: wrong, players_voted: voted, fool_points: points}),
    do: %{points: plus_points(points), text: "Fooled #{length(wrong)} of #{voted}."}

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

  # The finished game's awards as {title, rows, song}: each row a sentence,
  # with its award's name beside it when one slip holds two awards; the song
  # an award was won with, when there is one, has a row of its own.
  defp award_lines(%{awards: awards} = view) when is_map(awards) do
    case {bluff_line(view, awards.best_bluff), sharpest_line(view, awards.sharpest)} do
      # Both to the one winner: one slip with their name on its tape and a
      # row for each award, not the same name three times.
      {{_, _, _}, {_, _, _}} = both ->
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
          {
            "#{name_of(view, id)}’s awards",
            # The bluff last, so its song's row follows it.
            [
              {"Sharpest ears", "guessed #{awards.sharpest.called} right"},
              {"Best bluff", "fooled #{players(awards.best_bluff.fooled)}"}
            ],
            played_song(view, id, song)
          }
        ]

      _otherwise ->
        [bluff, sharpest]
    end
  end

  # An award is only handed out when it singles somebody out
  # (`Awards.given?/1`). Tied bluffs can be one player's songs, or two
  # players'.
  defp bluff_line(view, %{fooled: fooled, bluffs: bluffs} = award) do
    if Awards.given?(award) do
      bluff_award(view, fooled, bluffs, Enum.uniq_by(bluffs, & &1.player_id))
    end
  end

  defp bluff_line(_view, nil), do: nil

  # One player's one song: the song gets its own row.
  defp bluff_award(view, fooled, [%{song_name: song}], [%{player_id: id}]),
    do:
      {"Best bluff", [{nil, "#{name_of(view, id)} fooled #{players(fooled)}"}],
       played_song(view, id, song)}

  # One player, several songs that fooled as many.
  defp bluff_award(view, fooled, songs, [%{player_id: id}]),
    do:
      {"Best bluff",
       [
         {nil,
          "#{name_of(view, id)} fooled #{players(fooled)} with each of #{length(songs)} songs"}
       ], nil}

  # Several players level.
  defp bluff_award(view, fooled, _songs, holders) do
    names = holders |> Enum.map(&name_of(view, &1.player_id)) |> join_names()
    {"Best bluff", [{nil, "#{names} each fooled #{players(fooled)}"}], nil}
  end

  defp players(1), do: "1 player"
  defp players(n), do: "#{n} players"

  # The night's record of a song a player brought, for its row on an award.
  defp played_song(%{playlist: songs}, player_id, song_name) when is_list(songs) do
    Enum.find(songs, &(&1.player_id == player_id and &1.song_name == song_name)) ||
      %{song_name: song_name, album_art_url: nil}
  end

  defp played_song(_view, _player_id, song_name), do: %{song_name: song_name, album_art_url: nil}

  defp sharpest_line(view, %{called: called, player_ids: ids} = award) do
    if Awards.given?(award) do
      names = ids |> Enum.map(&name_of(view, &1)) |> join_names()
      each = if length(ids) > 1, do: " each", else: ""
      {"Sharpest ears", [{nil, "#{names}#{each} guessed #{called} right"}], nil}
    end
  end

  defp sharpest_line(_view, nil), do: nil

  defp winner_rows(board), do: Enum.filter(board, &(&1.rank == 1))

  # The line down a run of tied rows starts inside the run's first row and
  # ends inside its last, so two runs that meet (3rd tied, then 5th tied)
  # never join into one.
  defp tie_bracket(rows, row) do
    "relative before:absolute before:-left-4 before:w-[3px] " <>
      "before:bg-[color-mix(in_srgb,var(--color-jam-cream)_32%,var(--color-jam-night))] " <>
      "before:content-[''] " <>
      case tie_part(rows, row) do
        :first -> "before:top-2 before:-bottom-3"
        :middle -> "before:-inset-y-3"
        :last -> "before:-top-3 before:bottom-2"
      end
  end

  defp winner_headline([], _board), do: "Game over"
  defp winner_headline([winner], _board), do: "#{winner.name} wins"

  defp winner_headline(winners, board)
       when length(winners) == length(board) and length(board) > 2,
       do: "Everyone tied"

  defp winner_headline(winners, _board),
    do: "#{join_names(Enum.map(winners, & &1.name))} share the win"

  attr :winners, :list, required: true
  attr :board, :list, required: true

  # The winners' names, each kept whole: the line breaks between names, never
  # inside one ("Maximiliana-Rose / & Cleo"). What they did ("wins", "share
  # the win") is the line under it (`winner_points_line/1`); a table where
  # everyone tied says so instead.
  defp winner_names(%{winners: [_ | _] = winners, board: board} = assigns)
       when length(winners) < length(board) or length(board) <= 2 do
    assigns =
      assign(assigns,
        names: Enum.map(winners, & &1.name)
      )

    ~H"""
    <%= for {name, index} <- Enum.with_index(@names) do %>
      <span :if={index > 0 and index == length(@names) - 1}>&</span>
      <span class="whitespace-nowrap">{name}{if index < length(@names) - 2, do: ","}</span>
    <% end %>
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

  # The winner's own beat: the name alone, larger than a reveal's, as large
  # as its length leaves room for; tied names a step smaller, under their
  # posters.
  defp winner_card_size(winners, board) do
    case {length(winners), String.length(winner_label(winners, board))} do
      {1, n} when n <= 6 -> "text-[15rem]"
      {1, n} when n <= 10 -> "text-[12rem]"
      {_, n} when n <= 12 -> "text-[9rem]"
      {_, n} when n <= 18 -> "text-[7rem]"
      {_, n} when n <= 26 -> "text-[5.5rem]"
      _ -> "text-[4.5rem]"
    end
  end

  # The names as the headline sets them (or the line said instead of them).
  defp winner_label(winners, board) when length(winners) < length(board) or length(board) <= 2,
    do: join_names(Enum.map(winners, & &1.name))

  defp winner_label(winners, board), do: winner_headline(winners, board)

  # What the named winners did, said under their names; nothing when the
  # headline has said it already ("Everyone tied").
  defp winner_verb([_], _board), do: "wins"

  defp winner_verb(winners, board) when length(winners) < length(board) or length(board) <= 2,
    do: "share the win"

  defp winner_verb(_winners, _board), do: nil

  # One winner's name can be set large; names sharing the line need the room.
  defp winner_size_class(1), do: "text-[7.25rem]"
  defp winner_size_class(2), do: "text-[5.25rem]"
  defp winner_size_class(_count), do: "text-[3.5rem]"

  attr :winners, :list, required: true
  attr :verb, :string, default: nil

  # "wins with 11 points" (or "share the win with 9 points each"), the number
  # in the scores' lettering and orange.
  defp winner_points_line(assigns) do
    assigns =
      assign(assigns,
        lead: Enum.join(Enum.reject([assigns.verb, "with"], &is_nil/1), " "),
        score: hd(assigns.winners).score,
        tail: if(match?([_], assigns.winners), do: "", else: " each")
      )

    ~H"""
    {@lead} <span class="font-display text-jam-orange">{@score}</span>
    {if @score == 1, do: "point", else: "points"}{@tail}
    """
  end

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

  # Eight rows still leave room for the buttons under them; first place has
  # a row a little taller than the rest.
  defp final_row_size(board, true = _first?) when length(board) > 6,
    do: "py-2.5 text-[2.05rem] leading-tight"

  defp final_row_size(board, false) when length(board) > 6,
    do: "py-1.5 text-[1.85rem] leading-tight"

  defp final_row_size(_board, true), do: "py-3.5 text-[2.3rem]"
  defp final_row_size(_board, false), do: "py-2.5 text-[2.05rem]"

  defp join_names([name]), do: name
  defp join_names([a, b]), do: "#{a} & #{b}"

  defp join_names(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " & " <> last
  end
end
