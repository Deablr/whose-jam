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
    * The submitter doesn't guess whose song it is (they know); they forecast
      which *wrong* answer the room will fall for. A round may carry that
      `forecast` (a choice). It earns the submitter +1 when it is the wrong
      answer most players gave, or one of them when several tie for most. A
      forecast of an answer no player gave earns nothing. A forecast of the
      correct answer (the submitter naming themselves) predicts that nobody
      falls for it: +1 when at least one player voted and none was fooled.
      Audience votes count towards neither.
    * The submitter earns +1 more when their song split the room: at least
      one player called it and at least one player didn't (`split_room?/2`).
      A song nobody called is too obscure, one everybody called too obvious.
      Audience votes don't count either way.

  ## Return shape

  Returns a map of `id => non_neg_integer()` of deltas. Only ids that actually
  scored a non-zero delta appear in the result; ids with no delta are omitted.
  A caller that wants explicit zeros can merge against its own roster.

  Guarantee: `Enum.sum(Map.values(result)) == correct_votes + fooled_player_votes`,
  plus 1 when the forecast was right (`forecast_right?/2`) and 1 when the song
  split the room (`split_room?/2`), each while its way of scoring is on.
  """

  @type id :: String.t()

  @type round :: %{
          :style => :guess_who | :guess_question,
          :submitter_id => id(),
          :correct_choice => term(),
          optional(:forecast) => term()
        }

  @type vote :: %{
          voter_id: id(),
          voter_role: :player | :audience,
          choice: term()
        }

  @typedoc """
  Which of the four ways to score are on (all of them, unless said
  otherwise): `correct?` (+1 to a player's right guess; the audience's right
  guesses always score, as they are all an audience member can score),
  `fooled?` (+1 to the picker per player fooled), `predictions?` (+1 to the
  picker for a right forecast) and `split?` (+1 to the picker when the song
  split the room).
  """
  @type opts :: %{
          optional(:correct?) => boolean(),
          optional(:fooled?) => boolean(),
          optional(:predictions?) => boolean(),
          optional(:split?) => boolean()
        }

  @doc """
  Scores a single round.

  `opts` switches a way of scoring off (see `t:opts/0`); a switched-off way
  scores nothing, and the others are unchanged. See the module doc for the
  full ruleset and return shape.
  """
  @spec score_round(round(), [vote()], opts()) :: %{id() => non_neg_integer()}
  def score_round(
        %{submitter_id: submitter_id, correct_choice: correct_choice} = round,
        votes,
        opts \\ %{}
      )
      when is_list(votes) and is_map(opts) do
    on = Map.merge(%{correct?: true, fooled?: true, predictions?: true, split?: true}, opts)

    votes
    |> Enum.reduce(%{}, &tally(&1, &2, submitter_id, correct_choice, on))
    |> add_if(on.predictions? and forecast_right?(round, votes), submitter_id)
    |> add_if(on.split? and split_room?(round, votes), submitter_id)
  end

  @doc """
  Whether the round's song split the room: at least one player (not audience)
  voted for the correct answer and at least one voted for another.

  ## Examples

      iex> round = %{style: :guess_who, submitter_id: "a", correct_choice: "a"}
      iex> votes = [
      ...>   %{voter_id: "b", voter_role: :player, choice: "a"},
      ...>   %{voter_id: "c", voter_role: :player, choice: "b"}
      ...> ]
      iex> WhoseJam.Game.Scoring.split_room?(round, votes)
      true
      iex> WhoseJam.Game.Scoring.split_room?(round, tl(votes))
      false
  """
  @spec split_room?(round(), [vote()]) :: boolean()
  def split_room?(%{correct_choice: correct_choice}, votes) when is_list(votes) do
    {right, wrong} =
      votes
      |> Enum.reject(&(&1.voter_role == :audience))
      |> Enum.split_with(&(&1.choice == correct_choice))

    right != [] and wrong != []
  end

  @doc """
  Whether the round's `forecast` came true: it names the wrong answer most
  players gave (or one of those tied for most), or it names the correct
  answer and every player who voted (at least one) gave it. `false` for a
  round without a forecast.

  ## Examples

      iex> round = %{style: :guess_who, submitter_id: "a", correct_choice: "a", forecast: "b"}
      iex> votes = [%{voter_id: "c", voter_role: :player, choice: "b"}]
      iex> WhoseJam.Game.Scoring.forecast_right?(round, votes)
      true
  """
  @spec forecast_right?(round(), [vote()]) :: boolean()
  def forecast_right?(%{forecast: forecast, correct_choice: correct_choice}, votes)
      when not is_nil(forecast) and is_list(votes) do
    player_votes = Enum.reject(votes, &(&1.voter_role == :audience))

    wrong =
      player_votes
      |> Enum.reject(&(&1.choice == correct_choice))
      |> Enum.frequencies_by(& &1.choice)

    cond do
      forecast == correct_choice -> player_votes != [] and wrong == %{}
      Map.has_key?(wrong, forecast) -> wrong[forecast] == wrong |> Map.values() |> Enum.max()
      true -> false
    end
  end

  def forecast_right?(_round, _votes), do: false

  defp tally(vote, acc, submitter_id, correct_choice, on) do
    cond do
      # Correct guess: +1 to the voter (player or audience). The audience
      # always scores it: it is the only way they can score at all.
      vote.choice == correct_choice and (on.correct? or vote.voter_role == :audience) ->
        add(acc, vote.voter_id, 1)

      vote.choice == correct_choice ->
        acc

      # Incorrect guess: submitter is fooled only by non-audience voters.
      vote.voter_role == :audience ->
        acc

      on.fooled? ->
        add(acc, submitter_id, 1)

      true ->
        acc
    end
  end

  defp add(acc, id, points), do: Map.update(acc, id, points, &(&1 + points))

  defp add_if(acc, true, id), do: add(acc, id, 1)
  defp add_if(acc, false, _id), do: acc
end
