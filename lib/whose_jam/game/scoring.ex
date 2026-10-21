defmodule WhoseJam.Game.Scoring do
  @moduledoc """
  Pure per-round scoring for whose-jam.

  Given a single round and the votes cast in it, computes the point *deltas*
  earned this round only. No processes, no Repo, no side effects: plain data in,
  plain data out.

  ## Rules

    * A voter (player *or* audience) whose `choice` equals the round's
      `correct_choice` earns +1.
    * The submitter earns +1 for each *incorrect* vote cast by a *non-audience*
      voter — they "fooled" that player. Audience votes never generate
      fool-points.
    * Audience members can never be submitters; their scoring path is one-sided
      (they can earn guess points but never fool-points).
    * The same fooling rule applies to both `:guess_who` and `:guess_question`
      styles — a wrong guess by a player fools the submitter regardless of style.

  ## Return shape

  Returns a map of `id => non_neg_integer()` of deltas. Only ids that actually
  scored a non-zero delta appear in the result; ids with no delta are omitted.
  A caller that wants explicit zeros can merge against its own roster.

  Guarantee: `Enum.sum(Map.values(result)) == correct_votes + fooled_player_votes`.
  """

  @type id :: String.t()

  @type round :: %{
          style: :guess_who | :guess_question,
          submitter_id: id(),
          correct_choice: term()
        }

  @type vote :: %{
          voter_id: id(),
          voter_role: :player | :audience,
          choice: term()
        }

  @doc """
  Scores a single round.

  See the module doc for the full ruleset and return shape.
  """
  @spec score_round(round(), [vote()]) :: %{id() => non_neg_integer()}
  def score_round(%{submitter_id: submitter_id, correct_choice: correct_choice}, votes)
      when is_list(votes) do
    Enum.reduce(votes, %{}, &tally(&1, &2, submitter_id, correct_choice))
  end

  defp tally(vote, acc, submitter_id, correct_choice) do
    cond do
      # Correct guess: +1 to the voter (player or audience).
      vote.choice == correct_choice -> add(acc, vote.voter_id, 1)
      # Incorrect guess: submitter is fooled only by non-audience voters.
      vote.voter_role == :audience -> acc
      true -> add(acc, submitter_id, 1)
    end
  end

  defp add(acc, id, points), do: Map.update(acc, id, points, &(&1 + points))
end
