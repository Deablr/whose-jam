defmodule WhoseJam.Game.StandingsTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Game.Standings

  doctest Standings

  defp players(names), do: Enum.map(names, &%{id: String.downcase(&1), name: &1})

  defp places(rows), do: Enum.map(rows, &{&1.name, &1.rank, &1.tied?})

  describe "rank/2" do
    test "orders by score, best first" do
      rows = Standings.rank(players(~w(Ava Ben Cleo)), %{"ava" => 1, "ben" => 3, "cleo" => 2})

      assert places(rows) == [{"Ben", 1, false}, {"Cleo", 2, false}, {"Ava", 3, false}]
      assert Enum.map(rows, & &1.score) == [3, 2, 1]
    end

    test "equal scores share a place and the next place is skipped" do
      scores = %{"ava" => 7, "ben" => 8, "cleo" => 7, "dev" => 8, "eli" => 6}
      rows = Standings.rank(players(~w(Ava Ben Cleo Dev Eli)), scores)

      assert places(rows) == [
               {"Ben", 1, true},
               {"Dev", 1, true},
               {"Ava", 3, true},
               {"Cleo", 3, true},
               {"Eli", 5, false}
             ]
    end

    test "tied players keep the order they were given in" do
      rows = Standings.rank(players(~w(Cleo Ava Ben)), %{"ava" => 2, "ben" => 2, "cleo" => 2})

      assert Enum.map(rows, & &1.name) == ~w(Cleo Ava Ben)
      assert Enum.all?(rows, &(&1.rank == 1 and &1.tied?))
    end

    test "a participant with no score has 0" do
      rows = Standings.rank(players(~w(Ava Ben)), %{"ben" => 1})

      assert places(rows) == [{"Ben", 1, false}, {"Ava", 2, false}]
      assert List.last(rows).score == 0
    end

    test "nobody to rank is an empty board" do
      assert Standings.rank([], %{"gone" => 4}) == []
    end
  end

  describe "ordinal/1" do
    test "the teens all take th" do
      assert Enum.map(10..14, &Standings.ordinal/1) == ~w(10th 11th 12th 13th 14th)
    end

    test "st, nd and rd come back after twenty" do
      assert Enum.map(20..24, &Standings.ordinal/1) == ~w(20th 21st 22nd 23rd 24th)
    end
  end
end
