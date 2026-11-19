defmodule WhoseJam.Game.Bracket do
  @moduledoc """
  The rules of a head-to-head (`:vs`) game, as pure functions: plain data in,
  plain data out.

  Everyone picks a song for the same prompt. The songs meet two at a time;
  the room votes for the better one, in the open (who backs which song is
  shown as the votes land), and it goes through to the next stage, until one
  is left: the champion. A stage with an odd number of songs gives
  the last one a bye straight through.

  An entry is `%{player_id, song}` (the song as `WhoseJam.Music.Track`
  normalizes it). A matchup's two entries are `"a"` and `"b"`, the choices
  a vote names.

  ## Scoring

    * Each vote a song wins is +1 to whoever picked it.
    * A vote for one's own song doesn't count (anyone may cast it, so every
      phone has the same choices and gives nobody away).
    * The champion's picker gets +2 more (`champion_bonus/0`), when the final
      was played to a vote (the server decides: a lone song, a skipped final
      or a walkover crowns nobody).
  """

  @type entry :: %{required(:player_id) => String.t(), required(:song) => map()}
  @type side :: String.t()
  @type vote :: %{voter_id: String.t(), choice: side()}

  @champion_bonus 2

  @doc "What the champion's picker gets on top of their votes."
  @spec champion_bonus() :: pos_integer()
  def champion_bonus, do: @champion_bonus

  @doc """
  A stage's matchups, in order, two entries each, and the entry (if any)
  that goes through without playing: the last, when there is an odd number.

      iex> WhoseJam.Game.Bracket.pairs([:a, :b, :c])
      {[{:a, :b}], [:c]}
      iex> WhoseJam.Game.Bracket.pairs([:a, :b, :c, :d])
      {[{:a, :b}, {:c, :d}], []}
  """
  @spec pairs([term()]) :: {[{term(), term()}], [term()]}
  def pairs(entries) when is_list(entries) do
    {paired, bye} =
      if rem(length(entries), 2) == 1,
        do: Enum.split(entries, -1),
        else: {entries, []}

    {paired |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1), bye}
  end

  @doc """
  What a stage of `count` songs is called.

      iex> WhoseJam.Game.Bracket.stage_name(2)
      "Final"
      iex> WhoseJam.Game.Bracket.stage_name(3)
      "Semi-final"
      iex> WhoseJam.Game.Bracket.stage_name(7)
      "Quarter-final"
  """
  @spec stage_name(pos_integer()) :: String.t()
  def stage_name(count) when count <= 2, do: "Final"
  def stage_name(count) when count <= 4, do: "Semi-final"
  def stage_name(count) when count <= 8, do: "Quarter-final"
  def stage_name(_count), do: "First round"

  @doc """
  The votes each side won, leaving out a vote for one's own song.

      iex> a = %{player_id: "ava", song: %{}}
      iex> b = %{player_id: "ben", song: %{}}
      iex> votes = [
      ...>   %{voter_id: "ava", choice: "a"},
      ...>   %{voter_id: "cleo", choice: "a"},
      ...>   %{voter_id: "dev", choice: "b"}
      ...> ]
      iex> WhoseJam.Game.Bracket.tally({a, b}, votes)
      %{"a" => 1, "b" => 1}
  """
  @spec tally({entry(), entry()}, [vote()]) :: %{side() => non_neg_integer()}
  def tally({a, b}, votes) when is_list(votes) do
    pickers = %{"a" => a.player_id, "b" => b.player_id}

    counted =
      for %{choice: side, voter_id: voter} <- votes,
          side in ["a", "b"],
          voter != pickers[side],
          do: side

    Map.merge(%{"a" => 0, "b" => 0}, Enum.frequencies(counted))
  end

  @doc """
  The side the room is behind right now, which is the one the TV plays once
  both songs have had their clip. Every vote counts here, a picker's for
  their own song too: the count is public while the vote is open, and one
  left out would give away whose song it is. A tie keeps `current`.

      iex> votes = [%{voter_id: "ava", choice: "b"}, %{voter_id: "ben", choice: "b"}]
      iex> WhoseJam.Game.Bracket.leader(votes, "a")
      "b"
      iex> WhoseJam.Game.Bracket.leader([], "a")
      "a"
  """
  @spec leader([vote()], side()) :: side()
  def leader(votes, current) when is_list(votes) and current in ["a", "b"] do
    counts = Enum.frequencies(for %{choice: side} <- votes, side in ["a", "b"], do: side)
    winner(%{"a" => Map.get(counts, "a", 0), "b" => Map.get(counts, "b", 0)}, current)
  end

  @doc """
  The side that won the tally; a tie goes to `tiebreak` (a side chosen at
  random by the caller, so this stays pure).

      iex> WhoseJam.Game.Bracket.winner(%{"a" => 3, "b" => 1}, "b")
      "a"
      iex> WhoseJam.Game.Bracket.winner(%{"a" => 2, "b" => 2}, "b")
      "b"
  """
  @spec winner(%{side() => non_neg_integer()}, side()) :: side()
  def winner(%{"a" => a, "b" => b}, _tiebreak) when a > b, do: "a"
  def winner(%{"a" => a, "b" => b}, _tiebreak) when b > a, do: "b"
  def winner(_tally, tiebreak) when tiebreak in ["a", "b"], do: tiebreak

  @doc """
  The points a matchup is worth: each picker gets the votes their song won
  (only those who won any appear). One player who picked both songs (it
  can't happen in a game, but the sum stays honest) gets both counts.

      iex> a = %{player_id: "ava", song: %{}}
      iex> b = %{player_id: "ben", song: %{}}
      iex> WhoseJam.Game.Bracket.deltas({a, b}, %{"a" => 3, "b" => 0})
      %{"ava" => 3}
  """
  @spec deltas({entry(), entry()}, %{side() => non_neg_integer()}) :: %{
          String.t() => pos_integer()
        }
  def deltas({a, b}, tally) do
    [{a.player_id, tally["a"]}, {b.player_id, tally["b"]}]
    |> Enum.reject(fn {_id, n} -> n == 0 end)
    |> Enum.reduce(%{}, fn {id, n}, acc -> Map.update(acc, id, n, &(&1 + n)) end)
  end
end
