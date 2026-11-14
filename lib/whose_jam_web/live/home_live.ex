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
          <%!-- On a wide screen, lined up with the logo's speech bubble (not
               the lines drawn either side of it). --%>
          <p class="text-lg sm:text-2xl xl:text-3xl font-medium leading-snug text-jam-cream/70 max-w-xl xl:max-w-2xl text-balance lg:pl-[min(4.5rem,8.5vh)]">
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
          <%!-- Joining: the room code is typed onto a ticket, like the one the
               TV shows it on. The main thing on a phone; a slim row under
               hosting on a TV. --%>
          <%!-- Straight on the stage (no card: the ticket is the prop), and
               on a TV under a hairline. --%>
          <section class="order-1 space-y-4 pt-2 lg:order-2 lg:flex lg:items-center lg:gap-6 lg:space-y-0 lg:border-t lg:border-jam-cream/12 lg:pt-10">
            <h2 class="text-2xl font-extrabold tracking-[-0.015em] lg:shrink-0 lg:text-xl lg:font-bold lg:text-jam-cream/75 xl:text-2xl">
              {if @seat, do: "Join another game", else: "Join a game"}
            </h2>
            <form
              phx-submit="join"
              phx-change="validate_join"
              class="jam-ticket-wide flex flex-col gap-4 sm:flex-row lg:flex-1 lg:gap-0"
            >
              <%!-- The code is typed onto a ticket, like the one the TV shows
                   it on. On a TV the Join button is that ticket's stub, past
                   a perforation; on a phone it is the screen's pink button,
                   under it. --%>
              <%!-- Focus is a pink line under the code, inside the ticket,
                   so it follows the ticket's cut ends. Flat on the stage:
                   a lifting shadow would fall into its notches (dark dots)
                   and onto the button under it. --%>
              <div class="min-w-0 flex-1">
                <div class="jam-ticket [--jam-notch:0.55rem] lg:bg-transparent lg:[mask:none]">
                  <input
                    type="text"
                    name="code"
                    value={@join_code}
                    autocomplete="off"
                    autocapitalize="characters"
                    placeholder="Room code"
                    maxlength="4"
                    aria-label="Room code"
                    class="h-[4.4rem] w-full bg-transparent px-7 py-0 text-center lg:text-left font-display text-[2.5rem] leading-none uppercase tracking-[0.12em] text-jam-ink placeholder:text-jam-ink/60 placeholder-shown:pt-[1.4rem] placeholder-shown:font-body placeholder-shown:text-xl placeholder-shown:font-semibold placeholder-shown:normal-case placeholder-shown:tracking-normal focus:outline-none focus:shadow-[inset_0_-0.2rem_0_var(--color-jam-pink)] lg:text-[2.25rem] lg:placeholder-shown:text-xl"
                  />
                </div>
              </div>
              <button
                type="submit"
                class="jam-btn lg:rounded-none lg:border-l-2 lg:border-dashed lg:border-jam-ink/25 lg:bg-transparent lg:px-8 lg:text-[1.5rem] lg:font-extrabold lg:text-jam-ink lg:hover:bg-jam-ink/5 xl:text-[1.6rem]"
              >
                Join
              </button>
            </form>
          </section>

          <%!-- Hosting, straight on the stage: its headline, a line and the
               pink button, with no card round them. --%>
          <section class="order-2 hidden space-y-5 lg:order-1 lg:block">
            <div class="space-y-2">
              <h2 class="font-display text-5xl xl:text-6xl">Host a game</h2>
              <p class="font-medium text-balance text-jam-cream/70 xl:text-2xl">
                Pick a theme here on the TV. Everyone joins on their phone.
              </p>
            </div>
            <button
              type="button"
              phx-click="open_host"
              class="jam-btn w-full text-xl xl:text-3xl"
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
      class="max-w-3xl !border-0 !bg-transparent !p-0 !shadow-none lg:!max-w-[min(66vw,64rem)]"
      body_class="space-y-6"
    >
      <%!-- Read from the sofa on a TV: two-thirds of the screen wide, and
           set a size up there. --%>
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="font-display text-3xl leading-none lg:text-[2.75rem]">Pick a theme</h2>
        </div>
        <%!-- The same light close as the settings sheet's. --%>
        <button
          type="button"
          phx-click="close_host"
          aria-label="Close"
          class="grid size-11 cursor-pointer place-items-center rounded-md text-jam-cream/75 transition-colors hover:bg-jam-cream/10 hover:text-jam-cream focus-visible:bg-jam-cream/10"
        >
          <.icon name="hero-x-mark-solid" class="size-7" />
        </button>
      </div>

      <%!-- The themes side by side, each a sheet of paper laid on the table:
           its name, how it plays, and one of its prompts, with a "Host this"
           button at its foot (the two level). The whole sheet is that button
           (it stretches over it); it lifts under the pointer and is ringed
           only on focus. --%>
      <ul class="grid gap-8 pt-2 sm:grid-cols-2">
        <li
          :for={theme <- @themes}
          class="jam-paper jam-theme-card group relative flex flex-col gap-3 px-7 pb-6 pt-7 text-jam-ink lg:gap-4 lg:px-9 lg:pb-8 lg:pt-9"
        >
          <h3 class="font-display text-[2rem] leading-none lg:text-[2.6rem]">{theme.name}</h3>
          <%!-- Two lines kept for it on every card, so the prompts start level. --%>
          <p class="min-h-[2lh] text-[1.0625rem] font-medium leading-snug text-pretty text-jam-ink/70 lg:text-[1.35rem]">
            {how_it_plays(theme.style_sequence)}
          </p>
          <%!-- One of its prompts, quoted, past a dashed rule as the
               receipt's lines are. --%>
          <p
            :if={theme.examples != []}
            class="border-t-2 border-dashed border-jam-ink/15 pt-4 text-[1.0625rem] font-semibold leading-[1.3] text-pretty text-jam-ink/85 lg:text-[1.35rem]"
          >
            “{hd(theme.examples).prompt}”
          </p>
          <button
            phx-click="create"
            phx-value-theme={theme.id}
            class="mt-auto flex h-11 w-fit cursor-pointer items-center gap-2 rounded-md bg-jam-ink px-5 text-[1.0625rem] font-bold text-jam-cream transition-colors after:absolute after:inset-0 after:content-[''] group-hover:bg-[#2c2b28] focus-visible:outline-none lg:h-14 lg:px-7 lg:text-[1.35rem]"
          >
            Host this
            <.icon
              name="hero-arrow-right"
              class="size-[1.1em] transition-transform duration-150 group-hover:translate-x-1"
            />
          </button>
        </li>
      </ul>
    </.modal>
    """
  end

  # How a theme plays, from the styles of its rounds, in the order they come
  # (a theme of two styles plays them as two rounds).
  defp how_it_plays(styles) do
    case Enum.uniq(styles) do
      [:guess_who] -> "Guess who picked each song."
      [:guess_question] -> "Guess which prompt each song was picked for."
      [:guess_question, :guess_who] -> "Two rounds: guess the prompt, then the person."
      [:guess_who, :guess_question] -> "Two rounds: guess the person, then the prompt."
      _ -> "Pick songs, then guess."
    end
  end
end
