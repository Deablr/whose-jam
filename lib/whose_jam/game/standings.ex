defmodule WhoseJam.Game.Standings do
  @moduledoc """
  Ranks participants by score. Pure: plain data in, plain data out.

  Equal scores share a place and the next place is skipped (standard
  competition ranking): scores of 8, 8 and 7 are 1st, 1st and 3rd. No screen
  should ever present the order of two tied players as a result.
  """

  @typedoc "One participant's line on a scoreboard."
  @type row :: %{
          id: String.t(),
          name: String.t(),
          score: non_neg_integer(),
          rank: pos_integer(),
          tied?: boolean()
        }

  @doc """
  The participants as scoreboard rows, best score first.

  `participants` are maps with `:id` and `:name`; `scores` maps ids to points
  (a missing id scores 0). Participants on the same score keep the order they
  were given in, share a `rank`, and are marked `tied?`.

      iex> players = [%{id: "a", name: "Ava"}, %{id: "b", name: "Ben"}, %{id: "c", name: "Cleo"}]
      iex> rows = WhoseJam.Game.Standings.rank(players, %{"b" => 2, "c" => 2})
      iex> Enum.map(rows, &{&1.name, &1.rank, &1.tied?})
      [{"Ben", 1, true}, {"Cleo", 1, true}, {"Ava", 3, false}]
  """
  @spec rank([map()], %{optional(String.t()) => non_neg_integer()}) :: [row()]
  def rank(participants, scores) do
    rows =
      participants
      |> Enum.map(&%{id: &1.id, name: &1.name, score: Map.get(scores, &1.id, 0)})
      |> Enum.sort_by(& &1.score, :desc)

    counts = Enum.frequencies_by(rows, & &1.score)

    Enum.map(rows, fn row ->
      Map.merge(row, %{
        rank: 1 + Enum.count(rows, &(&1.score > row.score)),
        tied?: Map.fetch!(counts, row.score) > 1
      })
    end)
  end

  @doc """
  A place as people say it: `1` is `"1st"`, `22` is `"22nd"`.

      iex> Enum.map([1, 2, 3, 4, 11, 12, 13, 21, 102], &WhoseJam.Game.Standings.ordinal/1)
      ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "102nd"]
  """
  @spec ordinal(pos_integer()) :: String.t()
  def ordinal(place) when is_integer(place) and place > 0 do
    suffix =
      cond do
        rem(place, 100) in 11..13 -> "th"
        rem(place, 10) == 1 -> "st"
        rem(place, 10) == 2 -> "nd"
        rem(place, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{place}#{suffix}"
  end
end
