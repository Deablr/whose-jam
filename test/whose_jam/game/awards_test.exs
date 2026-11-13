defmodule WhoseJam.Game.AwardsTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Game.Awards

  doctest Awards

  defp round(submitter, song, fooled, called) do
    %{submitter_id: submitter, song_name: song, fooled: fooled, called: called}
  end

  test "no rounds, no awards" do
    assert Awards.summarize([]) == %{best_bluff: nil, sharpest: nil}
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
end
