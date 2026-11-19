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

  test "the split-the-room point is told while it's on" do
    on = HowToPlay.steps(%{style_sequence: [:guess_who]}, Map.put(@all_on, :score_split?, true))
    assert Enum.at(on, 2).body =~ "some call and some don’t"

    off = HowToPlay.steps(%{style_sequence: [:guess_who]}, Map.put(@all_on, :score_split?, false))
    refute Enum.at(off, 2).body =~ "some call"

    alone = HowToPlay.steps(%{style_sequence: [:guess_who]}, %{score_fooled?: false})
    assert Enum.at(alone, 2).body =~ "A song some call and some don’t is a point for you."
  end

  test "the audience is told what it does, and that a right guess always scores" do
    steps = HowToPlay.steps(%{style_sequence: [:guess_who]}, %{score_correct?: false}, :audience)

    assert [%{title: "The players pick songs"}, %{body: guess}, %{title: "Don’t be fooled"}] =
             steps

    assert guess =~ "a point for every right guess"
    refute Enum.any?(steps, &(&1.body =~ "Your phone gives you"))

    assert [%{body: pick}, _, %{body: points}] =
             HowToPlay.steps(%{style_sequence: [:vs]}, @all_on, :audience)

    assert pick == "Every player picks a song for the same prompt."
    assert points =~ "whoever picked it"
  end

  test "a prompt round asks for the prompt, and head to head has its own steps" do
    assert [_, %{title: "Guess the prompt"}, _] =
             HowToPlay.steps(%{style_sequence: [:guess_question]}, @all_on)

    assert [%{title: "One prompt, everyone"}, %{body: body}, %{title: "Last song standing"}] =
             HowToPlay.steps(%{style_sequence: [:vs]}, @all_on)

    assert body =~ "out in the open"
  end
end
