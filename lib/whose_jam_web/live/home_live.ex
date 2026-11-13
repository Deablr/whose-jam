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
        {:noreply, put_flash(socket, :error, "Couldn’t create that game. Please try again.")}
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
      class="jam-stage jam-home min-h-screen flex items-start px-6 pt-12 pb-10 sm:px-12 lg:items-center lg:px-20 lg:py-20"
    >
      <div class="w-full max-w-md mx-auto lg:max-w-none lg:mx-0 grid grid-cols-[minmax(0,1fr)] gap-8 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] lg:gap-[6vw] lg:items-center text-center lg:text-left">
        <header class="flex flex-col items-center lg:items-start gap-4 lg:gap-6">
          <img
            src={~p"/images/whose-jam-logo.svg"}
            alt="Whose Jam"
            class="w-48 sm:w-80 lg:w-full lg:max-w-[min(48rem,62vh*1.33)] lg:-ml-[4%]"
          />
          <p class="text-lg sm:text-2xl xl:text-3xl font-medium leading-snug text-jam-cream/70 max-w-xl xl:max-w-2xl text-balance">
            Everyone picks a song. The room guesses whose jam it is.
          </p>
        </header>

        <%!-- One main thing per screen: on a phone, joining; on a TV or a
             laptop, hosting (it comes first there, and joining waits under
             it). --%>
        <div class="flex flex-col gap-5 xl:gap-7">
          <%!-- A phone that left its game by accident goes straight back. --%>
          <.link
            :if={@seat}
            id="back-to-game"
            navigate={~p"/play/#{@seat}"}
            class="jam-btn w-full text-lg xl:text-2xl"
          >
            <span>Back to your game ({@seat})</span>
          </.link>
          <section class="jam-panel order-1 p-6 sm:p-8 xl:p-10 space-y-4 xl:space-y-5 lg:order-2">
            <h2 class="text-2xl font-extrabold tracking-[-0.015em] xl:text-4xl">
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
                class="flex-1 min-w-0 rounded-lg border-2 border-jam-cream/10 bg-jam-ink px-5 py-3 text-center lg:text-left text-3xl font-extrabold uppercase tracking-[0.3em] text-jam-cream placeholder:normal-case placeholder:tracking-normal placeholder:font-semibold placeholder:text-xl xl:text-4xl xl:placeholder:text-2xl placeholder:text-jam-cream/35 focus:border-jam-pink focus:outline-none"
              />
              <%!-- Pink where joining is the main thing (a phone); egg white
                   where hosting is (a TV), so a screen has one pink button. --%>
              <button
                type="submit"
                class="jam-btn lg:bg-jam-cream lg:hover:bg-white xl:text-2xl xl:px-10"
              >
                Join
              </button>
            </form>
          </section>

          <section class="jam-panel order-2 hidden p-6 sm:p-8 xl:p-10 space-y-4 xl:space-y-5 lg:order-1 lg:block">
            <div class="space-y-1">
              <h2 class="text-2xl font-extrabold tracking-[-0.015em] xl:text-4xl">Host a game</h2>
              <p class="font-medium text-balance text-jam-cream/65 xl:text-xl">
                Pick a theme here on the TV. Everyone joins on their phone.
              </p>
            </div>
            <button
              type="button"
              phx-click="open_host"
              class="jam-btn w-full xl:text-2xl"
            >
              Choose a theme
            </button>
          </section>

          <%!-- On a phone, hosting is a line, not a second panel. --%>
          <p class="order-3 text-sm font-medium text-jam-cream/65 lg:hidden">
            Hosting? Open this page on the TV, or <button
              type="button"
              phx-click="open_host"
              class="font-bold text-jam-cream/85 underline decoration-jam-cream/30 underline-offset-4 cursor-pointer"
            >
              host from here
            </button>.
          </p>
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
          <h2 class="mt-0.5 text-3xl font-extrabold tracking-[-0.02em]">Pick a theme</h2>
        </div>
        <button
          type="button"
          phx-click="close_host"
          aria-label="Close"
          class="jam-chip !px-2.5 cursor-pointer"
        >
          <.icon name="hero-x-mark-solid" class="size-5" />
        </button>
      </div>

      <%!-- Each theme a sheet of paper: its name on orange tape, what it is
           in a line, and one of its prompts as the players will get it. --%>
      <ul class="space-y-6 pt-2">
        <li
          :for={theme <- @themes}
          class="jam-paper flex flex-col gap-5 bg-jam-cream px-6 pb-6 pt-7 text-jam-ink sm:flex-row sm:items-end"
        >
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-3">
              <h3 class="jam-tape jam-tape-orange -ml-1 text-[1.6rem]">{theme.name}</h3>
              <span
                :if={multi_style?(theme.style_sequence)}
                class="rounded-sm bg-jam-ink/[0.07] px-2 py-0.5 text-xs font-bold text-jam-ink/65"
              >
                {length(Enum.uniq(theme.style_sequence))} sub-rounds
              </span>
            </div>
            <p class="mt-3 text-[0.9375rem] font-medium leading-snug text-jam-ink/70">
              {theme.description}
            </p>
            <p
              :if={theme.examples != []}
              class="mt-3 font-display text-[1.35rem] leading-[1.2] text-balance"
            >
              “{hd(theme.examples).prompt}”
            </p>
          </div>
          <button
            phx-click="create"
            phx-value-theme={theme.id}
            class="jam-btn shrink-0 self-start bg-jam-ink text-jam-cream hover:bg-black sm:self-end"
          >
            Host this <.icon name="hero-arrow-right-mini" class="size-5" />
          </button>
        </li>
      </ul>
    </.modal>
    """
  end

  defp multi_style?(styles), do: styles |> Enum.uniq() |> length() > 1
end
