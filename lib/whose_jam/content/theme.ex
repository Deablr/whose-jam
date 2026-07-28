defmodule WhoseJam.Content.Theme do
  @moduledoc """
  A curated pool of prompts. A theme's `style_sequence` is the ordered list of
  question styles that defines its sub-round structure (one sub-round per style).

  Styles are exposed to callers as atoms: `:guess_who`, `:guess_question`,
  `:guess_for_player` (the last reserved for future use, never seeded).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias WhoseJam.Content.Question

  @styles [:guess_who, :guess_question, :guess_for_player]

  @type t :: %__MODULE__{}

  schema "themes" do
    field :name, :string
    field :description, :string
    field :style_sequence, {:array, Ecto.Enum}, values: @styles, default: []

    has_many :questions, Question

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(theme, attrs) do
    theme
    |> cast(attrs, [:name, :description, :style_sequence])
    |> validate_required([:name])
    |> validate_length(:style_sequence, min: 1)
    |> unique_constraint(:name)
  end

  @doc "The full set of valid question styles."
  def styles, do: @styles
end
