defmodule WhoseJamWeb.HostLive do
  @moduledoc """
  Host console (`/host/:code`).

  The host's laptop runs this alongside the TV tab (`/tv/:code`) and their own
  phone player (`/play/:code`). It renders from `WhoseJam.Game.host_state/1`
  (the shared view plus the Spotify auth), lets the host tune settings and
  connect Spotify in the lobby, and exposes the in-game controls (skip a song,
  start a new game).
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.Game
  alias WhoseJam.Game.Config

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
    end

    socket =
      socket
      |> assign(code: code, page_title: "Host " <> code)
      |> load_state()

    {:ok, socket}
  end

  @impl true
  def handle_info({:game_state, _public}, socket) do
    # The broadcast payload omits the Spotify auth; refetch the host view so the
    # connect-status block always reflects the latest token/premium state.
    {:noreply, load_state(socket)}
  end

  @impl true
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

  defp load_state(socket) do
    assign(socket, view: Game.host_state(socket.assigns.code))
  end

  # Only forward the five host-facing settings; ignore any stray form fields
  # (like Phoenix's `_target`).
  defp config_overrides(params) do
    Map.take(params, ~w(answer_timer_s vote_timer_s questions_per_player
                        subrounds_enabled? allow_vote_change?))
  end

  defp start_error(:not_enough_players), do: "You need at least 3 players to start."
  defp start_error(:not_authenticated), do: "Connect a Spotify Premium account first."
  defp start_error(:not_premium), do: "That Spotify account isn't Premium — playback won't work."
  defp start_error(:already_started), do: "The game has already started."
  defp start_error(_), do: "Couldn't start the game. Please try again."

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(%{view: nil} = assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <main class="min-h-screen grid place-items-center bg-base-200 px-4 text-center">
      <div class="space-y-4">
        <h1 class="text-3xl font-bold">Game not found</h1>
        <p class="text-base-content/70">Room <span class="font-mono">{@code}</span> isn't live.</p>
        <.button navigate={~p"/"} variant="primary">Back to start</.button>
      </div>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="mx-auto max-w-3xl space-y-6">
        <header class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-2xl font-bold">Host console</h1>
            <p class="text-base-content/70">
              Room <span class="font-mono font-bold tracking-widest">{@code}</span>
              · {@view.theme.name}
            </p>
          </div>
          <div class="badge badge-lg badge-neutral">{phase_label(@view)}</div>
        </header>

        <.link navigate={~p"/tv/#{@code}"} class="btn btn-outline btn-block">
          Open the TV screen ↗
        </.link>

        <%= if @view.phase == :lobby do %>
          {lobby(assigns)}
        <% end %>

        <%= if @view.phase not in [:lobby, :finished] do %>
          {in_game(assigns)}
        <% end %>

        <%= if @view.phase == :finished do %>
          {finished(assigns)}
        <% end %>
      </div>
    </main>
    """
  end

  # ---- lobby --------------------------------------------------------------

  defp lobby(assigns) do
    assigns =
      assign(assigns,
        premium?: premium?(assigns.view.spotify),
        connected_spotify?: connected_spotify?(assigns.view.spotify),
        player_count: length(assigns.view.players),
        estimate: runtime_estimate(assigns.view)
      )

    ~H"""
    <div class="alert alert-warning">
      <.icon name="hero-exclamation-triangle" class="size-6 shrink-0" />
      <span>
        <span class="font-bold">Spotify Premium is required to host.</span>
        The TV plays full songs through your Premium account — connect it before you start.
      </span>
    </div>

    <section class="card bg-base-100 shadow">
      <div class="card-body space-y-3">
        <h2 class="card-title">Spotify</h2>
        <%= cond do %>
          <% @premium? -> %>
            <div class="alert alert-success">
              <.icon name="hero-check-circle" class="size-6 shrink-0" />
              <span>Spotify Premium connected. You're good to go.</span>
            </div>
          <% @connected_spotify? -> %>
            <div class="alert alert-error">
              <.icon name="hero-x-circle" class="size-6 shrink-0" />
              <span>Connected, but this account isn't Premium. Reconnect with a Premium account.</span>
            </div>
            <a href={~p"/auth/spotify?code=#{@code}"} class="btn btn-primary">
              Reconnect a Premium account
            </a>
          <% true -> %>
            <a href={~p"/auth/spotify?code=#{@code}"} class="btn btn-primary btn-lg">
              Connect Spotify (Premium required)
            </a>
        <% end %>
      </div>
    </section>

    <section class="card bg-base-100 shadow">
      <div class="card-body space-y-2">
        <div class="flex items-center justify-between">
          <h2 class="card-title">Players</h2>
          <span class="badge badge-lg">{@player_count} / 8</span>
        </div>
        <p :if={@player_count == 0} class="text-base-content/60">
          No one yet — share the TV screen so friends can scan in.
        </p>
        <ul class="flex flex-wrap gap-2">
          <li
            :for={p <- @view.players}
            class={["badge badge-lg gap-1", p.connected? || "badge-ghost opacity-60"]}
          >
            <span class={["inline-block size-2 rounded-full", dot_class(p.connected?)]} />
            {p.name}
          </li>
        </ul>

        <div :if={@view.audience != []} class="pt-2">
          <h3 class="text-sm font-semibold text-base-content/70">
            Audience ({length(@view.audience)})
          </h3>
          <ul class="flex flex-wrap gap-2 mt-1">
            <li :for={p <- @view.audience} class="badge badge-outline">{p.name}</li>
          </ul>
        </div>
      </div>
    </section>

    <section class="card bg-base-100 shadow">
      <div class="card-body space-y-1">
        <h2 class="card-title">Settings</h2>
        <p class="text-sm text-base-content/60">
          Estimated game length: <span class="font-semibold">~{@estimate} min</span>
        </p>
        <form phx-change="set_config" class="grid gap-2 sm:grid-cols-2">
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
            max="6"
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
        </form>
      </div>
    </section>

    <section class="card bg-base-100 shadow">
      <div class="card-body space-y-3">
        <button
          phx-click="start"
          disabled={not can_start?(@player_count, @premium?)}
          class="btn btn-primary btn-lg btn-block"
        >
          Start game
        </button>
        <p
          :if={not can_start?(@player_count, @premium?)}
          class="text-sm text-center text-base-content/70"
        >
          {start_blocker(@player_count, @premium?)}
        </p>
        <p class="text-sm text-center text-base-content/60">
          Want to play too? Join from your phone at <span class="font-mono font-semibold">/play/{@code}</span>.
        </p>
      </div>
    </section>
    """
  end

  # ---- in game ------------------------------------------------------------

  defp in_game(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow">
      <div class="card-body space-y-3">
        <h2 class="card-title">In progress</h2>
        <p class="text-base-content/80">{phase_detail(@view)}</p>

        <div :if={@view.subround_total > 1} class="text-sm text-base-content/60">
          Sub-round {@view.subround_index + 1} of {@view.subround_total}
        </div>

        <div :if={@view.phase == :playing and @view.round} class="text-sm text-base-content/60">
          Round {@view.round.index + 1} of {@view.round.total}
        </div>

        <button
          :if={@view.phase == :playing}
          phx-click="skip_song"
          data-confirm="Skip this song and move on?"
          class="btn btn-warning"
        >
          Skip song
        </button>
      </div>
    </section>
    """
  end

  # ---- finished -----------------------------------------------------------

  defp finished(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow">
      <div class="card-body space-y-3 text-center">
        <h2 class="card-title justify-center">Game over</h2>
        <p class="text-base-content/70">The final scoreboard is up on the TV.</p>
        <button phx-click="play_again" class="btn btn-primary btn-lg">
          Start a new game with these players
        </button>
      </div>
    </section>
    """
  end

  # =========================================================================
  # Helpers
  # =========================================================================

  defp premium?(spotify), do: connected_spotify?(spotify) and Map.get(spotify, :premium?) == true
  defp connected_spotify?(spotify), do: is_map(spotify)

  defp can_start?(player_count, premium?), do: player_count >= 3 and premium?

  defp start_blocker(player_count, premium?) do
    cond do
      player_count < 3 -> "Waiting for at least 3 players (#{player_count} joined)."
      not premium? -> "Connect a Spotify Premium account to start."
      true -> ""
    end
  end

  defp runtime_estimate(view) do
    player_count = max(length(view.players), 1)
    config = Config.build(view.config, player_count)

    subround_count =
      view.theme.style_sequence |> Enum.uniq() |> length() |> max(1)

    seconds = Config.estimated_runtime_s(config, player_count, subround_count)
    max(1, round(seconds / 60))
  end

  defp dot_class(true), do: "bg-success"
  defp dot_class(_), do: "bg-base-300"

  defp phase_label(%{phase: :lobby}), do: "Lobby"
  defp phase_label(%{phase: :answering}), do: "Answering"
  defp phase_label(%{phase: :finished}), do: "Finished"
  defp phase_label(%{phase: :playing, round_state: :revealing}), do: "Playing song"
  defp phase_label(%{phase: :playing, round_state: :voting}), do: "Voting"
  defp phase_label(%{phase: :playing, round_state: :results}), do: "Results"
  defp phase_label(%{phase: :playing}), do: "Playing"
  defp phase_label(_), do: "—"

  defp phase_detail(%{phase: :answering}),
    do: "Players are submitting songs on their phones. Heads down!"

  defp phase_detail(%{phase: :playing, round_state: :revealing}),
    do: "The song is playing on the TV."

  defp phase_detail(%{phase: :playing, round_state: :voting}),
    do: "Everyone is voting on who submitted this song."

  defp phase_detail(%{phase: :playing, round_state: :results}),
    do: "Revealing the submitter and the round's points."

  defp phase_detail(_), do: "In progress."
end
