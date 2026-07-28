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
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.{Game, Spotify}
  alias WhoseJamWeb.{Endpoint, Presence}

  @token_salt "player session"
  @token_max_age 4 * 60 * 60

  # =========================================================================
  # Mount
  # =========================================================================

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

        socket = assign(socket, player_id: player_id, status: :joined)
        {:ok, refresh_view(socket)}

      :error ->
        {:ok, assign(socket, status: :join)}
    end
  end

  defp default_assigns(code) do
    %{
      code: code,
      status: :loading,
      player_id: nil,
      view: nil,
      me: nil,
      role: nil,
      my_name: nil,
      page_title: "Join · WhoseJam",
      # answering
      q_index: 0,
      edit_qid: nil,
      search_query: "",
      search_results: [],
      spotify_error: nil,
      submitted_uris: MapSet.new(),
      show_times_up: false,
      # voting
      my_vote: nil,
      vote_error: nil,
      # join
      join_error: nil,
      audience_notice: false
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

  def handle_event("search", %{"q" => q}, socket) do
    query = String.trim(q)

    if query == "" do
      {:noreply, assign(socket, search_query: "", search_results: [], spotify_error: nil)}
    else
      {:noreply, run_search(socket, q)}
    end
  end

  def handle_event("pick_song", params, socket) do
    %{"uri" => uri, "question" => qid} = params

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
          |> assign(search_query: "", search_results: [], spotify_error: nil, edit_qid: nil)
          |> refresh_view()

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         assign(socket, spotify_error: "Couldn't lock in that pick — the timer may have ended.")}
    end
  end

  def handle_event("change_pick", %{"question" => qid}, socket) do
    {:noreply,
     assign(socket, edit_qid: qid, search_query: "", search_results: [], spotify_error: nil)}
  end

  def handle_event("next_q", _params, socket) do
    {:noreply, move_question(socket, +1)}
  end

  def handle_event("prev_q", _params, socket) do
    {:noreply, move_question(socket, -1)}
  end

  def handle_event("vote", %{"choice" => choice}, socket) do
    case Game.cast_vote(socket.assigns.code, socket.assigns.player_id, choice) do
      :ok ->
        {:noreply, socket |> assign(my_vote: choice, vote_error: nil) |> refresh_view()}

      {:error, :own_round} ->
        {:noreply, assign(socket, vote_error: nil)}

      {:error, :already_voted} ->
        {:noreply, assign(socket, vote_error: "Your vote is already locked in.")}

      {:error, _reason} ->
        {:noreply, assign(socket, vote_error: "Couldn't record that vote.")}
    end
  end

  def handle_event("dismiss_times_up", _params, socket) do
    {:noreply, assign(socket, show_times_up: false)}
  end

  # =========================================================================
  # Broadcasts
  # =========================================================================

  @impl true
  def handle_info({:game_state, _view}, socket) do
    {:noreply, refresh_view(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # =========================================================================
  # Internals
  # =========================================================================

  defp do_join(socket, name) do
    case Game.join(socket.assigns.code, name) do
      {:ok, %{player_id: player_id, role: role} = result} ->
        token =
          Phoenix.Token.sign(Endpoint, @token_salt, %{
            code: socket.assigns.code,
            player_id: player_id,
            role: role
          })

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

  defp run_search(socket, query) do
    case Spotify.search(query) do
      {:ok, results} ->
        assign(socket, search_query: query, search_results: results, spotify_error: nil)

      {:error, :not_configured} ->
        assign(socket,
          search_query: query,
          search_results: [],
          spotify_error: "Song search isn't set up on this server right now."
        )

      {:error, _other} ->
        assign(socket,
          search_query: query,
          search_results: [],
          spotify_error: "Couldn't reach Spotify — try that search again."
        )
    end
  end

  defp move_question(socket, delta) do
    assigned = assigned_questions(socket.assigns)
    max_index = max(length(assigned) - 1, 0)
    new_index = min(max(socket.assigns.q_index + delta, 0), max_index)

    assign(socket,
      q_index: new_index,
      edit_qid: nil,
      search_query: "",
      search_results: [],
      spotify_error: nil
    )
  end

  # Re-fetch the player-scoped view and recompute derived UI state.
  defp refresh_view(socket) do
    code = socket.assigns.code
    player_id = socket.assigns.player_id
    old_view = socket.assigns.view

    case Game.player_view(code, player_id) do
      nil ->
        assign(socket, status: :missing, view: nil, me: nil)

      %{me: nil} ->
        # Token points at a player the server no longer knows (e.g. a brand-new
        # game under the same code). Fall back to the join form.
        assign(socket, status: :join, view: nil, me: nil, player_id: nil)

      view ->
        me = view.me

        socket
        |> assign(
          status: :joined,
          view: view,
          me: me,
          role: me.role,
          my_name: participant_name(view, player_id),
          submitted_uris: merge_submitted_uris(socket.assigns.submitted_uris, me),
          show_times_up: compute_times_up(socket.assigns, old_view, view, me.role)
        )
    end
  end

  defp merge_submitted_uris(uris, %{assigned: assigned}) when is_list(assigned) do
    Enum.reduce(assigned, uris, fn
      %{song: %{uri: uri}}, acc when is_binary(uri) -> MapSet.put(acc, uri)
      _entry, acc -> acc
    end)
  end

  defp merge_submitted_uris(uris, _me), do: uris

  # True when the answer timer flipped us out of :answering with work left over.
  defp compute_times_up(assigns, old_view, new_view, role) do
    cond do
      new_view.phase in [:lobby, :finished] ->
        false

      role == :player and old_view != nil and old_view.phase == :answering and
          new_view.phase != :answering ->
        had_unfinished =
          case old_view.me do
            %{assigned: assigned} when is_list(assigned) ->
              Enum.any?(assigned, &(not &1.submitted?))

            _ ->
              false
          end

        had_unfinished or assigns.show_times_up

      true ->
        assigns.show_times_up
    end
  end

  defp valid_token(session, code) do
    with token when is_binary(token) <- Map.get(session, "player_token"),
         {:ok, %{code: ^code, player_id: player_id}} <-
           Phoenix.Token.verify(Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, player_id}
    else
      _ -> :error
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

  defp own_round?(assigns) do
    case assigns.view.round do
      %{song: %{uri: uri}} when is_binary(uri) -> MapSet.member?(assigns.submitted_uris, uri)
      _ -> false
    end
  end

  defp voted?(assigns) do
    assigns.player_id in (assigns.view.round.voters || [])
  end

  defp my_delta(assigns) do
    Map.get(assigns.view.round.deltas || %{}, assigns.player_id, 0)
  end

  defp scoreboard(view, role) do
    participants = if role == :audience, do: view.audience, else: view.players

    participants
    |> Enum.map(fn p -> Map.put(p, :score, Map.get(view.scores, p.id, 0)) end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp placement(view, player_id, role) do
    board = scoreboard(view, role)
    Enum.find_index(board, fn p -> p.id == player_id end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(str), do: str

  defp ordinal(0), do: "1st"
  defp ordinal(1), do: "2nd"
  defp ordinal(2), do: "3rd"
  defp ordinal(n), do: "#{n + 1}th"

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="min-h-screen bg-gradient-to-b from-fuchsia-950 via-indigo-950 to-slate-950 text-white">
      <div class="mx-auto flex min-h-screen w-full max-w-md flex-col px-5 pb-10 pt-6">
        <%= case @status do %>
          <% :missing -> %>
            {missing_screen(assigns)}
          <% :join -> %>
            {join_screen(assigns)}
          <% :joined -> %>
            {joined_screen(assigns)}
          <% _ -> %>
            <div class="flex flex-1 items-center justify-center text-white/60">Loading…</div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- top bar --------------------------------------------------------------

  defp top_bar(assigns) do
    ~H"""
    <div class="mb-6 flex items-center justify-between">
      <div class="text-2xl font-black tracking-tight">
        Whose<span class="text-fuchsia-400">Jam</span>
      </div>
      <div class="flex items-center gap-2">
        <span
          :if={@role}
          class={[
            "rounded-full px-3 py-1 text-xs font-bold uppercase tracking-wide",
            @role == :player && "bg-fuchsia-500/20 text-fuchsia-200",
            @role == :audience && "bg-sky-500/20 text-sky-200"
          ]}
        >
          {if @role == :player, do: "Player", else: "Audience"}
        </span>
        <span class="rounded-full bg-white/10 px-3 py-1 font-mono text-xs tracking-widest">
          {@code}
        </span>
      </div>
    </div>
    """
  end

  # --- game not found -------------------------------------------------------

  defp missing_screen(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col items-center justify-center gap-6 text-center">
      <div class="text-6xl">🫥</div>
      <div>
        <h1 class="text-2xl font-bold">No game here</h1>
        <p class="mt-2 text-white/60">
          We couldn't find a game with code <span class="font-mono font-semibold text-white">{@code}</span>. It may have ended.
        </p>
      </div>
      <.link navigate={~p"/"} class="rounded-2xl bg-fuchsia-500 px-6 py-3 font-semibold text-white">
        Back home
      </.link>
    </div>
    """
  end

  # --- join form ------------------------------------------------------------

  defp join_screen(assigns) do
    ~H"""
    {top_bar(assigns)}
    <div class="flex flex-1 flex-col justify-center">
      <h1 class="text-3xl font-black leading-tight">Pick a name<br />and jump in</h1>
      <p class="mt-2 text-white/60">
        Joining game <span class="font-mono font-semibold text-white">{@code}</span>. No account needed.
      </p>

      <form phx-submit="join" class="mt-8 space-y-4">
        <input
          type="text"
          name="name"
          autocomplete="off"
          autofocus
          maxlength="24"
          placeholder="Your display name"
          class="w-full rounded-2xl border border-white/10 bg-white/10 px-5 py-4 text-lg text-white placeholder-white/40 focus:border-fuchsia-400 focus:outline-none"
        />
        <p :if={@join_error} class="text-sm text-rose-300">{@join_error}</p>
        <button
          type="submit"
          class="w-full rounded-2xl bg-fuchsia-500 py-4 text-lg font-bold text-white active:scale-[0.98]"
        >
          Join the party
        </button>
      </form>
      <p class="mt-6 text-center text-xs text-white/40">
        The first 8 to join are players. After that you'll join as audience — still able to vote.
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
        <div class="flex flex-1 items-center justify-center text-white/60">Hang tight…</div>
    <% end %>
    """
  end

  # --- lobby ----------------------------------------------------------------

  defp lobby_screen(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col">
      <div class="rounded-3xl bg-white/5 p-6 text-center">
        <div class="text-5xl">🎉</div>
        <h1 class="mt-3 text-2xl font-bold">You're in, {@my_name}!</h1>
        <p class="mt-1 text-white/60">
          <%= if @role == :player do %>
            You'll get songs to submit once the host starts.
          <% else %>
            You're in the audience — you'll get to vote each round.
          <% end %>
        </p>
        <p class="mt-3 text-sm text-white/50">Waiting for the host to start…</p>
      </div>

      <div class="mt-6">
        <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-white/50">
          Players ({length(@view.players)})
        </h2>
        <div class="flex flex-wrap gap-2">
          <span
            :for={p <- @view.players}
            class={[
              "rounded-full px-3 py-1.5 text-sm font-medium",
              p.id == @player_id && "bg-fuchsia-500 text-white",
              p.id != @player_id && "bg-white/10 text-white/90"
            ]}
          >
            {p.name}
          </span>
        </div>

        <div :if={@view.audience != []} class="mt-5">
          <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-white/50">
            Audience ({length(@view.audience)})
          </h2>
          <div class="flex flex-wrap gap-2">
            <span
              :for={p <- @view.audience}
              class={[
                "rounded-full px-3 py-1.5 text-sm font-medium",
                p.id == @player_id && "bg-sky-500 text-white",
                p.id != @player_id && "bg-white/10 text-white/70"
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

  # --- answering ------------------------------------------------------------

  defp answering_screen(%{role: :audience} = assigns) do
    ~H"""
    <div class="flex flex-1 flex-col items-center justify-center gap-5 text-center">
      <div class="text-6xl">🎧</div>
      <h1 class="text-2xl font-bold">Players are picking songs</h1>
      <p class="text-white/60">Sit back — you'll vote once the music starts.</p>
      <div class="mt-2 rounded-2xl bg-white/5 px-6 py-4">
        <div class="text-xs uppercase tracking-wide text-white/50">Time left to submit</div>
        <div
          id="countdown-answer"
          phx-hook="Countdown"
          data-deadline={@view.answering.deadline_ms}
          class="mt-1 font-mono text-3xl font-bold"
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
      <div class="text-5xl">✅</div>
      <h1 class="text-xl font-bold">Nothing to submit this round</h1>
      <p class="text-white/60">Hang tight for the music.</p>
    </div>

    <div :if={@total > 0} class="flex flex-1 flex-col">
      <div class="mb-4 flex items-center justify-between">
        <div class="text-sm text-white/60">
          Question {@index + 1} of {@total} · {@answered}/{@total} submitted
        </div>
        <div class="flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1">
          <.icon name="hero-clock" class="size-4 text-fuchsia-300" />
          <span
            id="countdown-answer"
            phx-hook="Countdown"
            data-deadline={@view.answering.deadline_ms}
            class="font-mono text-sm font-semibold"
          >
            --
          </span>
        </div>
      </div>

      <div class="rounded-3xl bg-white/5 p-6">
        <div class="text-xs font-semibold uppercase tracking-wide text-fuchsia-300">Your prompt</div>
        <h1 class="mt-1 text-2xl font-bold leading-snug">{@question.prompt}</h1>
      </div>

      {answer_body(assigns)}

      <div class="mt-5 flex items-center justify-between">
        <button
          phx-click="prev_q"
          disabled={@index == 0}
          class="rounded-xl bg-white/10 px-5 py-3 font-medium disabled:opacity-30"
        >
          ← Prev
        </button>
        <div class="flex gap-1.5">
          <span
            :for={{q, i} <- Enum.with_index(@assigned)}
            class={[
              "size-2.5 rounded-full",
              i == @index && "bg-fuchsia-400",
              i != @index && q.submitted? && "bg-emerald-400",
              i != @index && not q.submitted? && "bg-white/20"
            ]}
          />
        </div>
        <button
          phx-click="next_q"
          disabled={@index >= @total - 1}
          class="rounded-xl bg-white/10 px-5 py-3 font-medium disabled:opacity-30"
        >
          Next →
        </button>
      </div>
    </div>
    """
  end

  # The search-or-submitted body for the current question.
  defp answer_body(assigns) do
    editing? = not assigns.question.submitted? or assigns.edit_qid == assigns.question.question_id
    assigns = assign(assigns, :editing?, editing?)

    ~H"""
    <div class="mt-5">
      <div :if={not @editing?} class="rounded-3xl border border-emerald-400/30 bg-emerald-400/10 p-4">
        <div class="mb-2 flex items-center gap-2 text-sm font-semibold text-emerald-300">
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
            <div class="truncate text-sm text-white/60">{@question.song.artist}</div>
          </div>
        </div>
        <button
          phx-click="change_pick"
          phx-value-question={@question.question_id}
          class="mt-4 w-full rounded-xl bg-white/10 py-3 text-sm font-medium"
        >
          Change pick
        </button>
      </div>

      <div :if={@editing?}>
        <form phx-change="search" class="mt-1">
          <input
            type="text"
            name="q"
            value={@search_query}
            autocomplete="off"
            phx-debounce="300"
            placeholder="Search Spotify for a song…"
            class="w-full rounded-2xl border border-white/10 bg-white/10 px-5 py-4 text-white placeholder-white/40 focus:border-fuchsia-400 focus:outline-none"
          />
        </form>

        <p :if={@spotify_error} class="mt-3 rounded-xl bg-rose-500/10 px-4 py-3 text-sm text-rose-200">
          {@spotify_error}
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
            class="flex w-full items-center gap-3 rounded-2xl bg-white/5 p-3 text-left active:bg-white/10"
          >
            <img
              :if={track.album_art_url}
              src={track.album_art_url}
              alt=""
              class="size-12 shrink-0 rounded-lg object-cover"
            />
            <div
              :if={!track.album_art_url}
              class="flex size-12 shrink-0 items-center justify-center rounded-lg bg-white/10"
            >
              <.icon name="hero-musical-note" class="size-6 text-white/50" />
            </div>
            <div class="min-w-0 flex-1">
              <div class="truncate font-semibold">{track.name}</div>
              <div class="truncate text-sm text-white/60">{track.artist}</div>
            </div>
          </button>
        </div>

        <p
          :if={@search_results == [] and @search_query != "" and is_nil(@spotify_error)}
          class="mt-3 text-center text-sm text-white/40"
        >
          No matches — try another search.
        </p>
      </div>
    </div>
    """
  end

  # --- playing (revealing / voting / results) -------------------------------

  defp playing_screen(assigns, round_state) do
    assigns =
      assigns
      |> assign(:round, assigns.view.round)
      |> assign(:round_state, round_state)

    ~H"""
    <div class="flex flex-1 flex-col">
      <div
        :if={@show_times_up}
        class="mb-4 flex items-start gap-2 rounded-2xl bg-amber-400/15 px-4 py-3 text-sm text-amber-100"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <span class="flex-1">Time's up — any unfinished questions won't be in the game.</span>
        <button phx-click="dismiss_times_up" aria-label="Dismiss">
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      {now_playing(assigns)}

      <%= case @round_state do %>
        <% :revealing -> %>
          {revealing_body(assigns)}
        <% :voting -> %>
          {voting_body(assigns)}
        <% :results -> %>
          {results_body(assigns)}
        <% _ -> %>
          <div class="mt-6 text-center text-white/60">…</div>
      <% end %>
    </div>
    """
  end

  defp now_playing(assigns) do
    ~H"""
    <div class="flex items-center gap-4 rounded-3xl bg-white/5 p-4">
      <img
        :if={@round.song.album_art_url}
        src={@round.song.album_art_url}
        alt=""
        class="size-16 rounded-xl object-cover"
      />
      <div
        :if={!@round.song.album_art_url}
        class="flex size-16 items-center justify-center rounded-xl bg-white/10"
      >
        <.icon name="hero-musical-note" class="size-7 text-white/50" />
      </div>
      <div class="min-w-0">
        <div class="text-xs uppercase tracking-wide text-white/40">
          Round {@round.index + 1} of {@round.total}
        </div>
        <div class="truncate text-lg font-bold">{@round.song.name}</div>
        <div class="truncate text-sm text-white/60">{@round.song.artist}</div>
      </div>
    </div>
    """
  end

  defp revealing_body(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col items-center justify-center gap-4 py-10 text-center">
      <div class="text-6xl">📺</div>
      <h1 class="text-xl font-bold">Listen up — it's playing on the TV</h1>
      <p class="text-white/60">Voting opens the moment the song wraps.</p>
    </div>
    """
  end

  defp voting_body(assigns) do
    cond do
      own_round?(assigns) ->
        ~H"""
        <div class="flex flex-1 flex-col items-center justify-center gap-4 py-10 text-center">
          <div class="text-6xl">🤫</div>
          <h1 class="text-xl font-bold">This one's yours</h1>
          <p class="text-white/60">Sit tight and see who you fooled.</p>
        </div>
        """

      voted?(assigns) and not assigns.view.config.allow_vote_change? ->
        ~H"""
        <div class="flex flex-1 flex-col items-center justify-center gap-4 py-10 text-center">
          <div class="text-6xl">✅</div>
          <h1 class="text-xl font-bold">Vote locked in</h1>
          <p class="text-white/60">Waiting on the reveal…</p>
          {vote_timer(assigns)}
        </div>
        """

      true ->
        assigns = assign(assigns, :can_change?, voted?(assigns))

        ~H"""
        <div class="mt-5 flex flex-1 flex-col">
          <div class="mb-3 flex items-center justify-between">
            <h1 class="text-lg font-bold">
              {if @round.style == :guess_who,
                do: "Who submitted this?",
                else: "Which prompt was this for?"}
            </h1>
            {vote_timer(assigns)}
          </div>

          <p :if={@can_change?} class="mb-3 text-sm text-emerald-300">
            Vote in — tap again to change it.
          </p>
          <p :if={@vote_error} class="mb-3 text-sm text-rose-300">{@vote_error}</p>

          <div class="space-y-2.5">
            <button
              :for={choice <- @round.choices}
              phx-click="vote"
              phx-value-choice={choice.id}
              class={[
                "w-full rounded-2xl px-5 py-4 text-left text-lg font-semibold active:scale-[0.99]",
                @my_vote == choice.id && "bg-fuchsia-500 text-white",
                @my_vote != choice.id && "bg-white/10 text-white"
              ]}
            >
              {if @round.style == :guess_who, do: choice.name, else: choice.prompt}
            </button>
          </div>
        </div>
        """
    end
  end

  defp vote_timer(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1">
      <.icon name="hero-clock" class="size-4 text-fuchsia-300" />
      <span
        id="countdown-vote"
        phx-hook="Countdown"
        data-deadline={@round.deadline_ms}
        class="font-mono text-sm font-semibold"
      >
        --
      </span>
    </div>
    """
  end

  defp results_body(assigns) do
    assigns =
      assigns
      |> assign(:delta, my_delta(assigns))
      |> assign(:submitter_name, participant_name(assigns.view, assigns.round.submitter_id))

    ~H"""
    <div class="mt-6 flex flex-1 flex-col items-center gap-5 text-center">
      <div class="rounded-3xl bg-white/5 px-6 py-5">
        <div :if={@round.style == :guess_who}>
          <div class="text-xs uppercase tracking-wide text-white/50">Submitted by</div>
          <div class="mt-1 text-2xl font-bold text-fuchsia-300">{@submitter_name}</div>
        </div>
        <div :if={@round.style != :guess_who}>
          <div class="text-xs uppercase tracking-wide text-white/50">The reveal</div>
          <div class="mt-1 text-lg font-semibold">Check the TV for the correct prompt.</div>
        </div>
      </div>

      <div class={[
        "rounded-2xl px-6 py-4 text-lg font-bold",
        @delta > 0 && "bg-emerald-500/20 text-emerald-200",
        @delta == 0 && "bg-white/5 text-white/60"
      ]}>
        <%= if @delta > 0 do %>
          +{@delta} {if @delta == 1, do: "point", else: "points"} this round!
        <% else %>
          No points this round
        <% end %>
      </div>
    </div>
    """
  end

  # --- finished -------------------------------------------------------------

  defp finished_screen(assigns) do
    assigns =
      assigns
      |> assign(:board, scoreboard(assigns.view, assigns.role))
      |> assign(:place, placement(assigns.view, assigns.player_id, assigns.role))

    ~H"""
    <div class="flex flex-1 flex-col">
      <div class="rounded-3xl bg-white/5 p-6 text-center">
        <div class="text-5xl">🏆</div>
        <h1 class="mt-3 text-2xl font-bold">That's a wrap!</h1>
        <p :if={@place != nil} class="mt-1 text-white/70">
          You finished <span class="font-bold text-fuchsia-300">{ordinal(@place)}</span>
          {if @role == :audience, do: "in the audience", else: "among players"}.
        </p>
      </div>

      <h2 class="mb-2 mt-6 text-sm font-semibold uppercase tracking-wide text-white/50">
        {if @role == :audience, do: "Audience scores", else: "Final scores"}
      </h2>
      <div class="space-y-2">
        <div
          :for={{p, i} <- Enum.with_index(@board)}
          class={[
            "flex items-center justify-between rounded-2xl px-4 py-3",
            p.id == @player_id && "bg-fuchsia-500/20",
            p.id != @player_id && "bg-white/5"
          ]}
        >
          <div class="flex items-center gap-3">
            <span class="w-6 text-center font-bold text-white/50">{i + 1}</span>
            <span class="font-semibold">{p.name}</span>
          </div>
          <span class="font-mono text-lg font-bold">{p.score}</span>
        </div>
      </div>

      <p class="mt-6 text-center text-sm text-white/40">
        Look up at the TV for the full results.
      </p>
    </div>
    """
  end
end
