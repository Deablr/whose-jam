defmodule WhoseJam.Game.AwardsTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Game.Awards

  doctest Awards

  defp round(submitter, song, fooled, called) do
    %{submitter_id: submitter, song_name: song, fooled: fooled, called: called}
  end

  test "no rounds, no awards" do
    assert Awards.summarize([]) == %{
             best_bluff: nil,
             sharpest: nil,
             most_fooled: nil,
             slowest_vote: nil,
             quickest_pick: nil
           }
  end

  test "a game in which nobody was fooled has no best bluff" do
    awards = Awards.summarize([round("ava", "Neon", 0, ["ben"])])

    assert awards.best_bluff == nil
    assert awards.sharpest == %{called: 1, player_ids: ["ben"]}
  end

  test "a game in which nobody was right has no sharpest player" do
    awards = Awards.summarize([round("ava", "Neon", 2, [])])

    assert awards.sharpest == nil
    assert awards.best_bluff == %{fooled: 2, bluffs: [%{player_id: "ava", song_name: "Neon"}]}
  end

  test "rounds that fooled equally many share the best bluff, in the order played" do
    awards =
      Awards.summarize([
        round("ava", "Neon", 3, []),
        round("ben", "Paper", 1, []),
        round("cleo", "Slow", 3, [])
      ])

    assert awards.best_bluff == %{
             fooled: 3,
             bluffs: [
               %{player_id: "ava", song_name: "Neon"},
               %{player_id: "cleo", song_name: "Slow"}
             ]
           }
  end

  test "players on equally many correct calls are all sharpest" do
    awards =
      Awards.summarize([
        round("ava", "Neon", 0, ["ben", "cleo"]),
        round("ben", "Paper", 0, ["cleo", "ava"]),
        round("cleo", "Slow", 0, ["ben"])
      ])

    assert awards.sharpest == %{called: 2, player_ids: ["ben", "cleo"]}
  end

  describe "given?/1" do
    test "an award is handed out when earned more than once, by up to two players" do
      bluff = fn fooled, holders ->
        %{fooled: fooled, bluffs: for(id <- holders, do: %{player_id: id, song_name: "Song"})}
      end

      assert Awards.given?(bluff.(2, ["ava"]))
      assert Awards.given?(bluff.(2, ["ava", "ben"]))
      refute Awards.given?(bluff.(2, ["ava", "ben", "cleo"]))
      # Fooling one player is no feat.
      refute Awards.given?(bluff.(1, ["ava"]))
      # Three tied songs of one player's are one holder.
      assert Awards.given?(bluff.(2, ["ava", "ava", "ava"]))
      refute Awards.given?(nil)
    end

    test "sharpest ears follows the same rule" do
      assert Awards.given?(%{called: 2, player_ids: ["ava"]})
      assert Awards.given?(%{called: 2, player_ids: ["ava", "ben"]})
      refute Awards.given?(%{called: 2, player_ids: ["ava", "ben", "cleo"]})
      refute Awards.given?(%{called: 1, player_ids: ["ava"]})
    end
  end

  describe "most fooled" do
    test "goes to whoever guessed wrong the most, ties shared in the order first missed" do
      rounds = [
        Map.put(round("ava", "Neon", 2, []), :missed, ["ben", "cleo"]),
        Map.put(round("ben", "Paper", 2, []), :missed, ["cleo", "dev"]),
        Map.put(round("cleo", "Slow", 1, []), :missed, ["ben"])
      ]

      assert Awards.summarize(rounds).most_fooled == %{missed: 2, player_ids: ["ben", "cleo"]}
    end

    test "is nobody's when nobody guessed wrong, and given only for more than one miss" do
      assert Awards.summarize([Map.put(round("ava", "Neon", 0, []), :missed, [])]).most_fooled ==
               nil

      refute Awards.given?(%{missed: 1, player_ids: ["ben"]})
      assert Awards.given?(%{missed: 2, player_ids: ["ben", "cleo"]})
      refute Awards.given?(%{missed: 2, player_ids: ["ben", "cleo", "dev"]})
    end
  end

  describe "slowest vote" do
    test "goes to the highest average time to lock in, over the rounds each voted in" do
      rounds = [
        Map.put(round("ava", "Neon", 0, []), :vote_ms, %{"ben" => 9_000, "cleo" => 2_000}),
        Map.put(round("ben", "Paper", 0, []), :vote_ms, %{"cleo" => 4_000, "dev" => 7_000}),
        Map.put(round("cleo", "Slow", 0, []), :vote_ms, %{"ben" => 1_000})
      ]

      # ben 5s on average, cleo 3s, dev 7s.
      assert Awards.summarize(rounds).slowest_vote == %{ms: 7_000, player_ids: ["dev"], of: 3}
    end

    test "is given only among at least three voters" do
      rounds = [
        Map.put(round("ava", "Neon", 0, []), :vote_ms, %{"ben" => 9_000, "cleo" => 1_000})
      ]

      award = Awards.summarize(rounds).slowest_vote

      assert award == %{ms: 9_000, player_ids: ["ben"], of: 2}
      refute Awards.given?(award)
    end
  end

  describe "quickest pick" do
    test "goes to whoever picked all their songs fastest" do
      picks = [
        %{player_id: "ava", ms: 30_000},
        %{player_id: "ben", ms: 12_000},
        %{player_id: "cleo", ms: 12_000},
        %{player_id: "dev", ms: 50_000}
      ]

      award = Awards.summarize([], picks).quickest_pick
      assert award == %{ms: 12_000, player_ids: ["ben", "cleo"], of: 4}
      assert Awards.given?(award)
    end

    test "is nobody's when nobody was timed" do
      assert Awards.summarize([], []).quickest_pick == nil
    end
  end
end
