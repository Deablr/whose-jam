defmodule WhoseJam.Content.Question do
  @moduledoc """
  A single prompt belonging to a theme.

  `style` is one of `:guess_who`, `:guess_question`, `:vs` (head to head:
  everyone answers the one prompt and the songs compete, see
  `WhoseJam.Game.Bracket`), or `:guess_for_player` (reserved, never seeded).
  `is_example` questions are preview-only: shown to hosts in the lobby and excluded from gameplay selection.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias WhoseJam.Content.Theme

  @styles [:guess_who, :guess_question, :vs, :guess_for_player]

  @type t :: %__MODULE__{}

  schema "questions" do
    field :prompt, :string
    field :style, Ecto.Enum, values: @styles
    field :is_example, :boolean, default: false

    belongs_to :theme, Theme

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(question, attrs) do
    question
    |> cast(attrs, [:theme_id, :prompt, :style, :is_example])
    |> validate_required([:theme_id, :prompt, :style])
    |> assoc_constraint(:theme)
  end
end
