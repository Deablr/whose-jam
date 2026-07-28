defmodule WhoseJam.Game.ScoringTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Game.Scoring

  # Helpers -------------------------------------------------------------------

  defp guess_who_round(submitter_id) do
    %{style: :guess_who, submitter_id: submitter_id, correct_choice: submitter_id}
  end

  defp vote(voter_id, choice, role \\ :player) do
    %{voter_id: voter_id, voter_role: role, choice: choice}
  end

  # A correct guess awards +1 -------------------------------------------------

  test "a correct guess awards +1 to the voter" do
    round = guess_who_round("sub")
    votes = [vote("p1", "sub")]

    assert Scoring.score_round(round, votes) == %{"p1" => 1}
  end

  test "audience correct votes score" do
    round = guess_who_round("sub")
    votes = [vote("a1", "sub", :audience)]

    assert Scoring.score_round(round, votes) == %{"a1" => 1}
  end

  # Submitter fool-points ------------------------------------------------------

  test "submitter gains +1 per fooled non-audience vote" do
    round = guess_who_round("sub")

    votes = [
      vote("p1", "sub"),
      vote("p2", "wrong"),
      vote("p3", "also_wrong")
    ]

    result = Scoring.score_round(round, votes)

    assert result["p1"] == 1
    assert result["sub"] == 2
    refute Map.has_key?(result, "p2")
    refute Map.has_key?(result, "p3")
  end

  test "audience wrong votes give the submitter nothing" do
    round = guess_who_round("sub")

    votes = [
      vote("a1", "wrong", :audience),
      vote("a2", "nope", :audience)
    ]

    assert Scoring.score_round(round, votes) == %{}
  end

  test "mix of audience and player wrong votes only fools on player votes" do
    round = guess_who_round("sub")

    votes = [
      vote("p1", "wrong"),
      vote("a1", "wrong", :audience)
    ]

    # Only the player vote fools the submitter.
    assert Scoring.score_round(round, votes) == %{"sub" => 1}
  end

  # All-correct / all-wrong ----------------------------------------------------

  test "all-correct round: submitter gets no fool-points, every voter +1" do
    round = guess_who_round("sub")

    votes = [
      vote("p1", "sub"),
      vote("p2", "sub"),
      vote("a1", "sub", :audience)
    ]

    result = Scoring.score_round(round, votes)

    assert result == %{"p1" => 1, "p2" => 1, "a1" => 1}
    refute Map.has_key?(result, "sub")
  end

  test "all-wrong round from players: submitter earns one per player vote" do
    round = guess_who_round("sub")

    votes = [
      vote("p1", "x"),
      vote("p2", "y"),
      vote("p3", "z")
    ]

    assert Scoring.score_round(round, votes) == %{"sub" => 3}
  end

  # Zero votes -----------------------------------------------------------------

  test "zero-vote round returns zero points" do
    round = guess_who_round("sub")

    assert Scoring.score_round(round, []) == %{}
  end

  # guess_question style -------------------------------------------------------

  test "a guess_question round scores analogously" do
    round = %{style: :guess_question, submitter_id: "sub", correct_choice: "q_right"}

    votes = [
      # correct question guess -> voter +1
      vote("p1", "q_right"),
      # wrong question guess by a player -> submitter fooled
      vote("p2", "q_wrong"),
      # wrong question guess by audience -> no fool-point
      vote("a1", "q_wrong", :audience),
      # correct question guess by audience -> voter +1
      vote("a2", "q_right", :audience)
    ]

    result = Scoring.score_round(round, votes)

    assert result == %{"p1" => 1, "a2" => 1, "sub" => 1}
  end

  # Sane totals ----------------------------------------------------------------

  test "sum of deltas equals correct_votes + fooled_player_votes" do
    round = guess_who_round("sub")

    votes = [
      vote("p1", "sub"),
      vote("p2", "wrong"),
      vote("p3", "wrong"),
      vote("a1", "sub", :audience),
      vote("a2", "wrong", :audience)
    ]

    result = Scoring.score_round(round, votes)

    correct_votes = Enum.count(votes, &(&1.choice == round.correct_choice))

    fooled_player_votes =
      Enum.count(votes, &(&1.choice != round.correct_choice and &1.voter_role != :audience))

    assert Enum.sum(Map.values(result)) == correct_votes + fooled_player_votes
  end

  test "all deltas are non-negative integers" do
    round = guess_who_round("sub")

    votes = [
      vote("p1", "sub"),
      vote("p2", "wrong"),
      vote("a1", "nope", :audience)
    ]

    result = Scoring.score_round(round, votes)

    assert Enum.all?(Map.values(result), &(is_integer(&1) and &1 >= 0))
  end
end
