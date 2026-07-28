defmodule WhoseJam.Content do
  @moduledoc """
  The static content layer: themed question pools seeded into Postgres.

  This context owns the only persistent data in the app (themes + questions).
  Runtime game state never touches the database.

  ## Question shape for gameplay

  `game_questions/2` returns the runtime question shape used across the game
  modules (see CLAUDE.md): `%{id: String.t(), prompt: String.t(), style: atom()}`.
  IDs are stringified so the rest of the system can treat all IDs uniformly.
  """

  import Ecto.Query, warn: false

  alias WhoseJam.Repo
  alias WhoseJam.Content.{Question, Theme}

  @doc """
  Lists all themes, ordered by name.
  """
  @spec list_themes() :: [Theme.t()]
  def list_themes do
    Theme
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Fetches a single theme by id. Raises `Ecto.NoResultsError` if none exists.
  """
  @spec get_theme!(term()) :: Theme.t()
  def get_theme!(id), do: Repo.get!(Theme, id)

  @doc """
  Returns the preview-only (`is_example: true`) questions for a theme.

  These are shown to hosts in the lobby and never enter gameplay selection.
  Returned as full `Question` structs (previews only need prompt + style).
  """
  @spec example_questions(term()) :: [Question.t()]
  def example_questions(theme_id) do
    Question
    |> where([q], q.theme_id == ^theme_id and q.is_example == true)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  @doc """
  Returns the gameplay-eligible questions for a theme and style, as runtime
  question maps: `%{id: String.t(), prompt: String.t(), style: atom()}`.

  Excludes `is_example: true` questions.
  """
  @spec game_questions(term(), atom()) :: [%{id: String.t(), prompt: String.t(), style: atom()}]
  def game_questions(theme_id, style) do
    Question
    |> where([q], q.theme_id == ^theme_id and q.style == ^style and q.is_example == false)
    |> order_by(asc: :id)
    |> select([q], %{id: q.id, prompt: q.prompt, style: q.style})
    |> Repo.all()
    |> Enum.map(fn q -> %{q | id: to_string(q.id)} end)
  end
end
