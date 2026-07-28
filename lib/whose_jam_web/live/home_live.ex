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
    {:ok, assign(socket, page_title: "whose-jam", themes: load_themes(), join_code: "")}
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

    <main class="min-h-screen bg-base-200 px-4 py-10 sm:py-16">
      <div class="mx-auto max-w-3xl space-y-10">
        <header class="text-center space-y-2">
          <h1 class="text-4xl sm:text-5xl font-black tracking-tight">whose-jam</h1>
          <p class="text-base-content/70 text-lg">
            A song-guessing party game for your TV and everyone's phones.
          </p>
        </header>

        <section class="card bg-base-100 shadow-xl">
          <div class="card-body space-y-2">
            <h2 class="card-title text-2xl">Join a game</h2>
            <p class="text-base-content/70">Got a room code from the TV? Punch it in.</p>
            <form phx-submit="join" phx-change="validate_join" class="flex flex-col sm:flex-row gap-3">
              <input
                type="text"
                name="code"
                value={@join_code}
                autocomplete="off"
                autocapitalize="characters"
                placeholder="CODE"
                maxlength="4"
                class="input input-lg input-bordered flex-1 uppercase tracking-[0.5em] text-center font-mono"
              />
              <.button variant="primary" class="btn btn-lg btn-primary">Join</.button>
            </form>
          </div>
        </section>

        <section class="space-y-4">
          <div class="text-center">
            <h2 class="text-2xl font-bold">Host a game</h2>
            <p class="text-base-content/70">Pick a vibe. You'll set it up on the next screen.</p>
          </div>

          <div class="grid gap-4 sm:grid-cols-2">
            <div :for={theme <- @themes} class="card bg-base-100 shadow-lg">
              <div class="card-body space-y-3">
                <div class="flex items-start justify-between gap-2">
                  <h3 class="card-title text-xl">{theme.name}</h3>
                </div>

                <div class="flex flex-wrap gap-1">
                  <span
                    :for={style <- Enum.uniq(theme.style_sequence)}
                    class="badge badge-secondary badge-sm"
                  >
                    {style_label(style)}
                  </span>
                  <span :if={multi_style?(theme.style_sequence)} class="badge badge-outline badge-sm">
                    sub-rounds
                  </span>
                </div>

                <p class="text-sm text-base-content/70">{theme.description}</p>

                <div :if={theme.examples != []} class="text-sm">
                  <p class="font-semibold text-base-content/80 mb-1">For example:</p>
                  <ul class="list-disc list-inside space-y-1 text-base-content/60">
                    <li :for={q <- theme.examples}>{q.prompt}</li>
                  </ul>
                </div>

                <div class="card-actions justify-end pt-1">
                  <button phx-click="create" phx-value-theme={theme.id} class="btn btn-primary">
                    Host this
                  </button>
                </div>
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
