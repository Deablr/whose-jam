defmodule WhoseJam.Game.BracketTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Game.Bracket

  doctest Bracket

  defp entry(id), do: %{player_id: id, song: %{uri: "x:" <> id}}
  defp vote(voter, side), do: %{voter_id: voter, choice: side}

  describe "pairs/1" do
    test "pairs the songs in order, and the odd one out has a bye" do
      assert Bracket.pairs([]) == {[], []}
      assert Bracket.pairs([:a]) == {[], [:a]}
      assert Bracket.pairs([:a, :b]) == {[{:a, :b}], []}
      assert Bracket.pairs([:a, :b, :c, :d, :e]) == {[{:a, :b}, {:c, :d}], [:e]}
    end

    test "halves the field each stage until one is left, from any number of songs" do
      for n <- 2..8 do
        stages =
          Stream.unfold(Enum.to_list(1..n), fn
            [_] ->
              nil

            entries ->
              {entries,
               then(Bracket.pairs(entries), fn {p, bye} -> Enum.map(p, &elem(&1, 0)) ++ bye end)}
          end)
          |> Enum.to_list()

        assert length(stages) == ceil(:math.log2(n))
      end
    end
  end

  describe "stage_name/1" do
    test "names a stage by how many songs are left in it" do
      assert Enum.map([2, 3, 4, 5, 8, 9], &Bracket.stage_name/1) ==
               [
                 "Final",
                 "Semi-final",
                 "Semi-final",
                 "Quarter-final",
                 "Quarter-final",
                 "First round"
               ]
    end
  end

  describe "tally/2, winner/2 and deltas/2" do
    test "a vote for one's own song doesn't count; every other one does" do
      matchup = {entry("ava"), entry("ben")}

      votes = [
        vote("ava", "a"),
        vote("ben", "a"),
        vote("cleo", "a"),
        vote("dev", "b"),
        vote("eli", "b")
      ]

      assert Bracket.tally(matchup, votes) == %{"a" => 2, "b" => 2}
      assert Bracket.deltas(matchup, %{"a" => 2, "b" => 2}) == %{"ava" => 2, "ben" => 2}
    end

    test "no votes is a tie at nothing, settled by the tiebreak, worth nothing" do
      matchup = {entry("ava"), entry("ben")}
      tally = Bracket.tally(matchup, [])

      assert tally == %{"a" => 0, "b" => 0}
      assert Bracket.winner(tally, "a") == "a"
      assert Bracket.winner(tally, "b") == "b"
      assert Bracket.deltas(matchup, tally) == %{}
    end

    test "the side with more votes wins whatever the tiebreak" do
      assert Bracket.winner(%{"a" => 1, "b" => 0}, "b") == "a"
      assert Bracket.winner(%{"a" => 0, "b" => 4}, "a") == "b"
    end

    test "a vote for neither side is ignored" do
      assert Bracket.tally({entry("ava"), entry("ben")}, [vote("cleo", "c")]) ==
               %{"a" => 0, "b" => 0}
    end
  end
end
