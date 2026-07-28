defmodule WhoseJam.Repo.Migrations.CreateContentTables do
  use Ecto.Migration

  def change do
    create table(:themes) do
      add :name, :string, null: false
      add :description, :text
      add :style_sequence, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:themes, [:name])

    create table(:questions) do
      add :theme_id, references(:themes, on_delete: :delete_all), null: false
      add :prompt, :text, null: false
      add :style, :string, null: false
      add :is_example, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:questions, [:theme_id])
    create index(:questions, [:theme_id, :style, :is_example])
  end
end
