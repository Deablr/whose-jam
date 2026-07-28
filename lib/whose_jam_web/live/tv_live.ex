defmodule WhoseJamWeb.TvLive do
  @moduledoc """
  The shared TV screen (`/tv/:code`).

  A pure renderer of `WhoseJam.Game.get_state/1`, styled big and dark for a
  living-room TV. It also drives Spotify playback: it holds the host's Premium
  access token (from `Game.host_state/1`, since the TV URL is deliberately not
  identity-bound) and hands it to the `SpotifyPlayer` JS hook.

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
        page_title: "TV " <> code,
        view: Game.get_state(code),
        join_url: join_url,
        qr_svg: qr_svg(join_url),
        playback_error: nil
      )
      |> assign_playback()

    {:ok, socket}
  end

  @impl true
  def handle_info({:game_state, view}, socket) do
    socket = assign(socket, view: view)

    # If we haven't got a token yet (e.g. host connected Spotify after the TV
    # mounted, or just started the game), try again now.
    socket =
      if is_nil(socket.assigns.spotify_token), do: assign_playback(socket), else: socket

    {:noreply, socket}
  end

  def handle_info(:refresh_token, socket) do
    {:noreply, assign_playback(socket)}
  end

  @impl true
  def handle_event("song_ended", _params, socket) do
    Game.song_ended(socket.assigns.code)
    {:noreply, socket}
  end

  def handle_event("playback_ready", _params, socket) do
    {:noreply, assign(socket, playback_error: nil)}
  end

  def handle_event("playback_error", params, socket) do
    {:noreply, assign(socket, playback_error: playback_error_message(params))}
  end

  # =========================================================================
  # Playback token
  # =========================================================================

  defp assign_playback(socket) do
    case usable_spotify(socket.assigns.code) do
      {:ok, spotify} ->
        {token, expires_at} = ensure_fresh_token(socket.assigns.code, spotify)
        schedule_token_refresh(expires_at)
        assign(socket, spotify_token: token, spotify_status: :ok)

      {:unavailable, reason} ->
        assign(socket, spotify_token: nil, spotify_status: {:unavailable, reason})
    end
  end

  defp usable_spotify(code) do
    case Game.host_state(code) do
      %{spotify: spotify} when is_map(spotify) ->
        if Map.get(spotify, :premium?) == true do
          {:ok, spotify}
        else
          {:unavailable, "The host's Spotify account isn't Premium, so playback is disabled."}
        end

      _ ->
        {:unavailable, "Waiting for the host to connect Spotify."}
    end
  end

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

  defp schedule_token_refresh(nil), do: :ok

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
    do: "No Spotify token — the host may need to reconnect."

  defp playback_error_message(%{"reason" => "authentication_error"}),
    do: "Spotify rejected the token — the host may need to reconnect."

  defp playback_error_message(%{"reason" => "account_error"}),
    do: "Spotify playback needs a Premium account."

  defp playback_error_message(_), do: "Spotify playback is unavailable right now."

  defp playback_banner(assigns) do
    cond do
      assigns.view.phase in [:lobby, :finished] -> nil
      assigns.playback_error -> assigns.playback_error
      match?({:unavailable, _}, assigns.spotify_status) -> elem(assigns.spotify_status, 1)
      true -> nil
    end
  end

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(%{view: nil} = assigns) do
    ~H"""
    <div class="min-h-screen grid place-items-center bg-black text-white text-center">
      <div class="space-y-4">
        <h1 class="text-6xl font-black">No game here</h1>
        <p class="text-2xl text-white/60">Room {@code} isn't live.</p>
      </div>
    </div>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, banner: playback_banner(assigns))

    ~H"""
    <div class="min-h-screen bg-black text-white overflow-hidden">
      <div
        :if={@banner}
        class="fixed top-0 inset-x-0 z-50 bg-amber-500 text-black text-center py-2 font-semibold"
      >
        Playback unavailable — {@banner}
      </div>

      <div
        :if={@spotify_status == :ok}
        id="spotify-player"
        phx-hook="SpotifyPlayer"
        data-token={@spotify_token}
        data-uri={play_uri(@view)}
        class="hidden"
      >
      </div>

      <%= case @view.phase do %>
        <% :lobby -> %>
          {tv_lobby(assigns)}
        <% :answering -> %>
          {tv_answering(assigns)}
        <% :playing -> %>
          {tv_playing(assigns)}
        <% :finished -> %>
          {tv_finished(assigns)}
      <% end %>
    </div>
    """
  end

  # ---- lobby --------------------------------------------------------------

  defp tv_lobby(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center gap-8 px-8 py-12">
      <div class="text-center space-y-1">
        <p class="text-2xl uppercase tracking-[0.4em] text-white/50">whose-jam</p>
        <h1 class="text-4xl font-bold">{@view.theme.name}</h1>
        <p class="text-xl text-white/60 max-w-2xl">{@view.theme.description}</p>
      </div>

      <div class="flex flex-col md:flex-row items-center gap-10">
        <div class="text-center">
          <p class="text-2xl text-white/60 mb-2">Join at {@join_url}</p>
          <div class="bg-black p-3 rounded-2xl">{raw(@qr_svg)}</div>
        </div>
        <div class="text-center">
          <p class="text-3xl text-white/60 uppercase tracking-widest mb-2">Room code</p>
          <p class="text-8xl md:text-9xl font-black font-mono tracking-widest">{@view.code}</p>
        </div>
      </div>

      <div class="w-full max-w-3xl space-y-4">
        <div>
          <h2 class="text-2xl font-semibold mb-2">
            Players <span class="text-white/50">({length(@view.players)}/8)</span>
          </h2>
          <div :if={@view.players == []} class="text-white/40 text-xl">
            Waiting for players to join…
          </div>
          <div class="flex flex-wrap gap-3">
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
          <div class="flex flex-wrap gap-2">
            <span :for={p <- @view.audience} class="px-3 py-1 rounded-full text-lg bg-white/5">
              {p.name}
            </span>
          </div>
        </div>
      </div>

      <p class="text-2xl text-white/50 animate-pulse">Waiting for the host to start…</p>
    </div>
    """
  end

  # ---- answering ----------------------------------------------------------

  defp tv_answering(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center gap-10 px-8 text-center">
      <div class="space-y-2">
        <h1 class="text-7xl font-black">Heads down! 🎧</h1>
        <p class="text-3xl text-white/60">Everyone's picking their songs.</p>
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

  defp tv_playing(%{view: %{round: nil}} = assigns) do
    ~H"""
    <div class="min-h-screen grid place-items-center text-center">
      <p class="text-4xl text-white/60">Loading the next song…</p>
    </div>
    """
  end

  defp tv_playing(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col lg:flex-row items-center justify-center gap-12 px-10 py-12">
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
            {tv_voting(assigns)}
          <% :results -> %>
            {tv_results(assigns)}
          <% _ -> %>
        <% end %>
      </div>
    </div>
    """
  end

  defp tv_voting(assigns) do
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

  defp tv_results(assigns) do
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

      {tv_scoreboard(assigns)}
    </div>
    """
  end

  # ---- finished -----------------------------------------------------------

  defp tv_finished(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center gap-10 px-8 py-12 text-center">
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
    </div>
    """
  end

  # A compact running scoreboard for between rounds (players only — the
  # "official" board is submitters).
  defp tv_scoreboard(assigns) do
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
