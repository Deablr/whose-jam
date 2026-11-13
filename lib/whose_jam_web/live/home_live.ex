defmodule WhoseJamWeb.HomeLive do
  @moduledoc """
  Landing page.

  Two things happen here: a host picks a themed pool and creates a game (which
  navigates to the host screen, which doubles as the TV display), or someone joins an existing game by typing a
  room code (which navigates to the player screen — the join UX itself lives in
  `PlayLive`).

  A device that still holds a seat in a game that is on (its session's
  `WhoseJamWeb.PlayerToken`) is offered the way back first, so a phone that
  left by accident needn't find the code again. `?host` opens the theme picker
  straight away (the TV's closing card links here to host another game).
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.{Content, Game}
  alias WhoseJamWeb.PlayerToken

  @impl true
  def mount(params, session, socket) do
    {:ok,
     assign(socket,
       page_title: "A song-guessing party game",
       themes: load_themes(),
       join_code: "",
       host_open?: Map.has_key?(params, "host"),
       seat: live_seat(session)
     )}
  end

  # The room code of the game this device has a seat in, while that game is
  # on and still knows the player.
  defp live_seat(session) do
    with {:ok, code, player_id} <- PlayerToken.seat(session),
         %{me: %{}} <- Game.player_view(code, player_id) do
      code
    else
      _ -> nil
    end
  end

  defp load_themes do
    Content.list_themes()
    |> Enum.map(fn theme ->
      %{
        id: theme.id,
        name: theme.name,
        description: theme.description,
        style_sequence: theme.style_sequence,
        examples: Content.example_questions(theme.id) |> Enum.take(3)
      }
    end)
  end

  @impl true
  def handle_event("create", %{"theme" => theme_id}, socket) do
    case WhoseJam.Game.create_game(theme_id) do
      {:ok, code} ->
        {:noreply, push_navigate(socket, to: ~p"/host/#{code}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't create that game. Please try again.")}
    end
  end

  def handle_event("open_host", _params, socket) do
    {:noreply, assign(socket, host_open?: true)}
  end

  def handle_event("close_host", _params, socket) do
    {:noreply, assign(socket, host_open?: false)}
  end

  def handle_event("join", %{"code" => code}, socket) do
    normalized = normalize_code(code)

    if normalized == "" do
      {:noreply, put_flash(socket, :error, "Enter a room code to join.")}
    else
      {:noreply, push_navigate(socket, to: ~p"/play/#{normalized}")}
    end
  end

  def handle_event("validate_join", %{"code" => code}, socket) do
    {:noreply, assign(socket, join_code: normalize_code(code))}
  end

  defp normalize_code(code) do
    code
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
    |> String.slice(0, 4)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- In the game's own colours, like every other screen's notices. --%>
    <div data-theme="jam"><Layouts.flash_group flash={@flash} /></div>

    <main
      data-theme="jam"
      class="jam-stage jam-home min-h-screen flex items-center px-6 sm:px-12 lg:px-20 py-12 lg:py-20"
    >
      <div class="w-full max-w-md mx-auto lg:max-w-none lg:mx-0 grid grid-cols-[minmax(0,1fr)] gap-12 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] lg:gap-[6vw] lg:items-center text-center lg:text-left">
        <header class="flex flex-col items-center lg:items-start gap-6">
          <img
            src={~p"/images/whose-jam-logo.svg"}
            alt="Whose Jam"
            class="w-72 sm:w-96 lg:w-full lg:max-w-[min(48rem,62vh*1.33)] lg:-ml-[4%]"
          />
          <p class="text-xl sm:text-2xl xl:text-3xl text-jam-cream/75 max-w-xl xl:max-w-2xl">
            The party game where everyone picks a song and the room guesses whose jam it is.
          </p>
        </header>

        <div class="space-y-6 xl:space-y-8">
          <%!-- A phone that left its game by accident goes straight back. --%>
          <.link
            :if={@seat}
            id="back-to-game"
            navigate={~p"/play/#{@seat}"}
            class="jam-btn w-full text-lg xl:text-2xl"
          >
            <span>Back to your game · <span class="tracking-widest">{@seat}</span></span>
          </.link>
          <section class="jam-panel p-6 sm:p-8 xl:p-10 space-y-4 xl:space-y-5">
            <h2 class="font-display text-3xl xl:text-5xl">
              {if @seat, do: "Join another game", else: "Join a game"}
            </h2>
            <form phx-submit="join" phx-change="validate_join" class="flex flex-col sm:flex-row gap-3">
              <input
                type="text"
                name="code"
                value={@join_code}
                autocomplete="off"
                autocapitalize="characters"
                placeholder="Room code"
                maxlength="4"
                aria-label="Room code"
                class="flex-1 min-w-0 rounded-2xl border-2 border-jam-cream/10 bg-jam-ink/60 px-5 py-4 text-center lg:text-left font-display text-3xl xl:text-5xl uppercase tracking-[0.3em] text-jam-cream placeholder:normal-case placeholder:tracking-normal placeholder:text-xl xl:placeholder:text-3xl placeholder:text-jam-cream/30 focus:border-jam-pink focus:outline-none"
              />
              <button type="submit" class="jam-btn xl:text-2xl xl:px-10">Join</button>
            </form>
          </section>

          <section class="jam-panel p-6 sm:p-8 xl:p-10 space-y-4 xl:space-y-5">
            <div class="space-y-1">
              <h2 class="font-display text-3xl xl:text-5xl">Host a game</h2>
              <p class="text-jam-cream/60 xl:text-xl">Put it on the TV and pick a theme.</p>
            </div>
            <button
              type="button"
              phx-click="open_host"
              class="jam-btn jam-btn-orange w-full xl:text-2xl"
            >
              Choose a theme
            </button>
          </section>
        </div>
      </div>

      {host_picker(assigns)}
    </main>
    """
  end

  defp host_picker(assigns) do
    ~H"""
    <.modal
      :if={@host_open?}
      id="host-game-modal"
      on_close="close_host"
      class="max-w-3xl"
      body_class="space-y-6"
    >
      <div class="flex items-start justify-between gap-4">
        <div>
          <p class="jam-eyebrow">Host a game</p>
          <h2 class="font-display text-4xl">Pick a theme</h2>
        </div>
        <button
          type="button"
          phx-click="close_host"
          aria-label="Close"
          class="jam-chip !px-2.5 cursor-pointer"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <ul class="space-y-3">
        <li
          :for={theme <- @themes}
          class="rounded-box border border-jam-cream/10 bg-base-200 p-5 flex flex-col sm:flex-row gap-5 sm:items-center"
        >
          <div class="flex-1 min-w-0 space-y-2">
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="font-display text-2xl">{theme.name}</h3>
              <span
                :if={multi_style?(theme.style_sequence)}
                class="jam-chip !py-0.5 !px-2.5 text-xs"
              >
                {length(Enum.uniq(theme.style_sequence))} sub-rounds
              </span>
            </div>
            <%!-- What the host is choosing, in a line: how this one is played. --%>
            <p class="text-lg font-bold text-jam-cream">{how_it_plays(theme.style_sequence)}</p>
            <p class="text-sm text-jam-cream/70">{theme.description}</p>
            <p :if={theme.examples != []} class="text-base text-jam-cream/65">
              Like: “{hd(theme.examples).prompt}”
            </p>
          </div>
          <button
            phx-click="create"
            phx-value-theme={theme.id}
            class="jam-btn shrink-0 self-start sm:self-center"
          >
            Host this
          </button>
        </li>
      </ul>
    </.modal>
    """
  end

  defp multi_style?(styles), do: styles |> Enum.uniq() |> length() > 1

  # How a theme plays, from the styles of its rounds, in the order they come.
  defp how_it_plays(styles) do
    case Enum.uniq(styles) do
      [:guess_who] -> "Guess who picked each song."
      [:guess_question] -> "Guess which prompt each song was picked for."
      [:guess_question, :guess_who] -> "Guess the prompt, then guess the person."
      [:guess_who, :guess_question] -> "Guess the person, then guess the prompt."
      _ -> "Pick songs, then guess."
    end
  end
end
