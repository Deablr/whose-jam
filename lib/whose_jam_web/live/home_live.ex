defmodule WhoseJamWeb.HomeLive do
  @moduledoc """
  Landing page.

  Two things happen here: a host picks a themed pool and creates a game (which
  navigates to the host console), or someone joins an existing game by typing a
  room code (which navigates to the player screen — the join UX itself lives in
  `PlayLive`).
  """
  use WhoseJamWeb, :live_view

  alias WhoseJam.Content

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "A song-guessing party game",
       themes: load_themes(),
       join_code: ""
     )}
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
    <Layouts.flash_group flash={@flash} />

    <main data-theme="jam" class="jam-stage min-h-screen px-4 py-10 sm:py-16">
      <div class="jam-halftone fixed inset-x-0 top-0 h-[50vh] -z-10"></div>

      <div class="mx-auto max-w-3xl space-y-14">
        <header class="text-center space-y-5">
          <p class="jam-path">C://users/you/party/whose-jam.exe</p>
          <div class="flex flex-col items-center">
            <span class="jam-sticker jam-sticker-ghost text-2xl -rotate-3 opacity-60">whose jam</span>
            <span class="jam-sticker jam-sticker-ghost text-3xl rotate-1 opacity-80 -mt-4 ml-8">
              whose jam
            </span>
            <h1 class="jam-sticker text-5xl sm:text-6xl -rotate-1 -mt-4 ml-16">whose jam?</h1>
          </div>
          <p class="text-white/75 text-lg max-w-md mx-auto">
            A song-guessing party game for your TV and everyone's phones.
          </p>
        </header>

        <section class="jam-panel p-6 sm:p-8 space-y-4">
          <div class="flex items-center justify-between gap-3">
            <h2 class="font-display text-2xl font-black">Join a game</h2>
            <span class="jam-path hidden sm:inline">got a code from the TV?</span>
          </div>
          <form phx-submit="join" phx-change="validate_join" class="flex flex-col sm:flex-row gap-3">
            <input
              type="text"
              name="code"
              value={@join_code}
              autocomplete="off"
              autocapitalize="characters"
              placeholder="CODE"
              maxlength="4"
              class="flex-1 rounded-2xl border-2 border-jam-bubblegum/30 bg-jam-night/70 px-5 py-4 text-center font-display text-3xl font-black uppercase tracking-[0.4em] text-jam-lemon placeholder-white/25 focus:border-jam-mint focus:outline-none"
            />
            <button type="submit" class="jam-btn text-lg">Join</button>
          </form>
        </section>

        <section class="space-y-6">
          <div class="text-center space-y-2">
            <h2 class="jam-sticker jam-sticker-lemon text-xl rotate-1">Host a game</h2>
            <p class="text-white/65">Pick a vibe. You'll set it up on the next screen.</p>
          </div>

          <div class="grid gap-6 sm:grid-cols-2">
            <div :for={theme <- @themes} class="jam-panel p-6 flex flex-col gap-4">
              <div class="space-y-3">
                <h3 class="jam-glitch text-2xl font-black leading-tight">{theme.name}</h3>
                <div class="flex flex-wrap gap-1.5">
                  <span
                    :for={style <- Enum.uniq(theme.style_sequence)}
                    class="jam-chip !py-0.5 !px-2.5 text-xs"
                  >
                    {style_label(style)}
                  </span>
                  <span
                    :if={multi_style?(theme.style_sequence)}
                    class="jam-chip jam-chip-on !py-0.5 !px-2.5 text-xs"
                  >
                    sub-rounds
                  </span>
                </div>
              </div>

              <p class="text-sm text-white/70">{theme.description}</p>

              <div :if={theme.examples != []} class="text-sm space-y-1.5">
                <p class="jam-path">for example:</p>
                <ul class="space-y-1.5 text-white/60">
                  <li :for={q <- theme.examples} class="flex gap-2">
                    <span class="text-jam-pink">▸</span><span>{q.prompt}</span>
                  </li>
                </ul>
              </div>

              <div class="mt-auto pt-2 flex justify-end">
                <button
                  phx-click="create"
                  phx-value-theme={theme.id}
                  class="jam-btn jam-btn-mint text-sm"
                >
                  Host this
                </button>
              </div>
            </div>
          </div>
        </section>
      </div>
    </main>
    """
  end

  defp style_label(:guess_who), do: "Guess Who"
  defp style_label(:guess_question), do: "Guess the Question"
  defp style_label(:guess_for_player), do: "Guess for Player"
  defp style_label(other), do: to_string(other)

  defp multi_style?(styles), do: styles |> Enum.uniq() |> length() > 1
end
