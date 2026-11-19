defmodule WhoseJamWeb.HowToPlayTest do
  use ExUnit.Case, async: true

  alias WhoseJamWeb.HowToPlay

  doctest HowToPlay

  @all_on %{score_correct?: true, score_fooled?: true, score_predictions?: true}

  test "a guessing round says how to pick, guess and bluff, with the points left on" do
    steps = HowToPlay.steps(%{style_sequence: [:guess_who]}, @all_on)

    assert Enum.map(steps, & &1.title) == [
             "Pick your songs",
             "Guess whose jam",
             "Keep a straight face"
           ]

    assert Enum.at(steps, 1).body =~ "a point for every right guess"
    assert Enum.at(steps, 2).body =~ "Every friend your song fools is a point"

    off =
      HowToPlay.steps(%{style_sequence: [:guess_who]}, %{
        score_correct?: false,
        score_fooled?: false
      })

    refute Enum.at(off, 1).body =~ "point"
    refute Enum.at(off, 2).body =~ "fools"
  end

  test "a prompt round asks for the prompt, and head to head has its own steps" do
    assert [_, %{title: "Guess the prompt"}, _] =
             HowToPlay.steps(%{style_sequence: [:guess_question]}, @all_on)

    assert [%{title: "One prompt, everyone"}, %{body: body}, %{title: "Last song standing"}] =
             HowToPlay.steps(%{style_sequence: [:vs]}, @all_on)

    assert body =~ "out in the open"
  end
end
