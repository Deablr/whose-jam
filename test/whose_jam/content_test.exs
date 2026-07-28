defmodule WhoseJam.ContentTest do
  @moduledoc """
  Light contract tests for the static content layer. These target the public
  `Content` API and the runtime question shape other modules depend on.
  """

  use WhoseJam.DataCase, async: true

  alias WhoseJam.Content
  alias WhoseJam.Content.{Question, Theme}

  defp insert_theme(attrs \\ %{}) do
    defaults = %{
      name: "Theme #{System.unique_integer([:positive])}",
      description: "desc",
      style_sequence: [:guess_who]
    }

    %Theme{}
    |> Theme.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_question(theme, attrs) do
    %Question{}
    |> Question.changeset(Map.merge(%{theme_id: theme.id}, attrs))
    |> Repo.insert!()
  end

  describe "list_themes/0 and get_theme!/1" do
    test "list_themes returns all themes ordered by name" do
      insert_theme(%{name: "Zeta"})
      insert_theme(%{name: "Alpha"})

      names = Content.list_themes() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
      assert "Alpha" in names and "Zeta" in names
    end

    test "get_theme! fetches by id and raises when missing" do
      theme = insert_theme()
      assert Content.get_theme!(theme.id).id == theme.id
      assert_raise Ecto.NoResultsError, fn -> Content.get_theme!(-1) end
    end

    test "style_sequence round-trips as atoms" do
      theme = insert_theme(%{style_sequence: [:guess_who, :guess_question]})
      assert Content.get_theme!(theme.id).style_sequence == [:guess_who, :guess_question]
    end
  end

  describe "example_questions/1" do
    test "returns only is_example: true questions for the theme" do
      theme = insert_theme()
      insert_question(theme, %{prompt: "example", style: :guess_who, is_example: true})
      insert_question(theme, %{prompt: "gameplay", style: :guess_who, is_example: false})

      other = insert_theme()
      insert_question(other, %{prompt: "other example", style: :guess_who, is_example: true})

      prompts = Content.example_questions(theme.id) |> Enum.map(& &1.prompt)
      assert prompts == ["example"]
    end
  end

  describe "game_questions/2" do
    test "returns runtime shape %{id: string, prompt, style}, excluding examples and other styles" do
      theme = insert_theme()
      q = insert_question(theme, %{prompt: "play me", style: :guess_who, is_example: false})
      insert_question(theme, %{prompt: "preview", style: :guess_who, is_example: true})
      insert_question(theme, %{prompt: "wrong style", style: :guess_question, is_example: false})

      assert [result] = Content.game_questions(theme.id, :guess_who)
      assert result == %{id: to_string(q.id), prompt: "play me", style: :guess_who}
      assert is_binary(result.id)
    end

    test "returns [] when no matching gameplay questions exist" do
      theme = insert_theme()
      assert Content.game_questions(theme.id, :guess_question) == []
    end
  end
end
