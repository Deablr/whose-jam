defmodule WhoseJam.Game.Awards do
  @moduledoc """
  What a finished game is remembered for, beyond the scores. Pure: plain data
  in, plain data out.

  Two awards, from the rounds that were played to a reveal:

    * **best bluff** — the song that fooled the most players, and who picked it;
    * **sharpest** — whoever called the most songs correctly.

  Ties are shared, never broken: every round that fooled the most is a best
  bluff, and everyone on the most correct calls is sharpest. An award nobody
  earned (nobody fooled, nobody right) is `nil`.
  """

  @typedoc """
  One round as it ended: who picked the song, how many players they fooled
  (their fool-points), and which players called it.
  """
  @type played_round :: %{
          submitter_id: String.t(),
          song_name: String.t(),
          fooled: non_neg_integer(),
          called: [String.t()]
        }

  @type t :: %{
          best_bluff:
            %{
              fooled: pos_integer(),
              bluffs: [%{player_id: String.t(), song_name: String.t()}]
            }
            | nil,
          sharpest: %{called: pos_integer(), player_ids: [String.t()]} | nil
        }

  @doc """
  The awards for `rounds`, given in the order they were played (which is the
  order tied winners are listed in).

      iex> rounds = [
      ...>   %{submitter_id: "ava", song_name: "Neon", fooled: 1, called: ["ben", "cleo"]},
      ...>   %{submitter_id: "ben", song_name: "Paper", fooled: 2, called: ["cleo"]}
      ...> ]
      iex> WhoseJam.Game.Awards.summarize(rounds)
      %{
        best_bluff: %{fooled: 2, bluffs: [%{player_id: "ben", song_name: "Paper"}]},
        sharpest: %{called: 2, player_ids: ["cleo"]}
      }
  """
  @spec summarize([played_round()]) :: t()
  def summarize(rounds) do
    %{best_bluff: best_bluff(rounds), sharpest: sharpest(rounds)}
  end

  defp best_bluff(rounds) do
    case rounds |> Enum.map(& &1.fooled) |> Enum.max(fn -> 0 end) do
      0 ->
        nil

      most ->
        bluffs =
          for %{fooled: ^most} = round <- rounds,
              do: %{player_id: round.submitter_id, song_name: round.song_name}

        %{fooled: most, bluffs: bluffs}
    end
  end

  defp sharpest(rounds) do
    # Keeps the order in which each player first called one.
    callers = rounds |> Enum.flat_map(& &1.called) |> Enum.uniq()
    counts = rounds |> Enum.flat_map(& &1.called) |> Enum.frequencies()

    case counts |> Map.values() |> Enum.max(fn -> 0 end) do
      0 -> nil
      most -> %{called: most, player_ids: Enum.filter(callers, &(counts[&1] == most))}
    end
  end
end
