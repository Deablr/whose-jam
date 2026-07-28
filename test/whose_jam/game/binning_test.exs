defmodule WhoseJam.Game.BinningTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Game.Binning

  # --- Helpers -------------------------------------------------------------

  defp players(n), do: Enum.map(1..n, &"player-#{&1}")

  defp questions(n) do
    Enum.map(1..n, fn i ->
      %{id: "q-#{i}", prompt: "Prompt #{i}", style: :guess_who}
    end)
  end

  # question id => [player id] flattened back to {player, question} pairs
  defp pairs(assignment) do
    for {qid, pids} <- assignment, pid <- pids, do: {pid, qid}
  end

  defp counts_per_player(assignment) do
    assignment
    |> pairs()
    |> Enum.frequencies_by(fn {pid, _qid} -> pid end)
  end

  # --- Target-count correctness -------------------------------------------

  test "every player is assigned exactly questions_per_player when the pool is large enough" do
    assignment = Binning.assign(players(8), questions(30), 3, seed: 1)

    for {_pid, count} <- counts_per_player(assignment) do
      assert count == 3
    end

    assert map_size(counts_per_player(assignment)) == 8
  end

  test "target count holds across a range of sizes and seeds" do
    for p <- 3..8, qpp <- 1..4, seed <- 1..10 do
      pool = questions(40)
      assignment = Binning.assign(players(p), pool, qpp, seed: seed)

      per_player = counts_per_player(assignment)

      assert map_size(per_player) == p,
             "expected #{p} players assigned (p=#{p}, qpp=#{qpp}, seed=#{seed})"

      for {_pid, count} <- per_player do
        assert count == qpp,
               "expected #{qpp} questions per player (p=#{p}, qpp=#{qpp}, seed=#{seed})"
      end
    end
  end

  # --- No-duplicate guarantee ---------------------------------------------

  test "no player is ever assigned the same question twice" do
    for p <- 3..8, qpp <- 1..5, seed <- 1..15 do
      assignment = Binning.assign(players(p), questions(20), qpp, seed: seed)

      # every question's submitter list has no dupes
      for {_qid, pids} <- assignment do
        assert length(pids) == length(Enum.uniq(pids))
      end

      # and no {player, question} pair repeats
      all_pairs = pairs(assignment)
      assert length(all_pairs) == length(Enum.uniq(all_pairs))
    end
  end

  # --- >= 2 submitter overlap guarantee -----------------------------------

  test "every selected question has at least 2 submitters (3 players)" do
    for qpp <- 1..4, seed <- 1..20 do
      assignment = Binning.assign(players(3), questions(20), qpp, seed: seed)

      for {qid, pids} <- assignment do
        assert length(pids) >= 2,
               "question #{qid} had #{length(pids)} submitters (qpp=#{qpp}, seed=#{seed})"
      end
    end
  end

  test "every selected question has at least 2 submitters (8 players)" do
    for qpp <- 1..4, seed <- 1..20 do
      assignment = Binning.assign(players(8), questions(30), qpp, seed: seed)

      for {qid, pids} <- assignment do
        assert length(pids) >= 2,
               "question #{qid} had #{length(pids)} submitters (qpp=#{qpp}, seed=#{seed})"
      end
    end
  end

  test "prefers reusing questions: uses no more than floor(total_slots / 2) questions" do
    # 8 players * 3 = 24 slots => at most 12 questions to keep >= 2 each,
    # even though the pool has 30 available.
    assignment = Binning.assign(players(8), questions(30), 3, seed: 7)
    assert map_size(assignment) <= div(8 * 3, 2)
  end

  # --- Minimum player count (3) -------------------------------------------

  test "works at the minimum player count of 3" do
    assignment = Binning.assign(players(3), questions(6), 2, seed: 3)

    assert map_size(counts_per_player(assignment)) == 3

    for {_pid, count} <- counts_per_player(assignment), do: assert(count == 2)
    for {_qid, pids} <- assignment, do: assert(length(pids) >= 2)
  end

  # --- More questions requested than exist --------------------------------

  test "degrades gracefully when more questions are requested than the pool holds" do
    # only 4 questions, but 6 requested per player
    assignment = Binning.assign(players(4), questions(4), 6, seed: 2)

    per_player = counts_per_player(assignment)
    assert map_size(per_player) == 4

    # a player can get at most the whole pool (4) distinct questions
    for {_pid, count} <- per_player do
      assert count == 4
    end

    # no duplicates per player, and every question still has >= 2 submitters
    for {_qid, pids} <- assignment do
      assert pids == Enum.uniq(pids)
      assert length(pids) >= 2
    end
  end

  test "empty question pool yields an empty assignment without crashing" do
    assert Binning.assign(players(3), [], 3, seed: 1) == %{}
  end

  test "empty player list yields an empty assignment without crashing" do
    assert Binning.assign([], questions(5), 3, seed: 1) == %{}
  end

  # --- Determinism ---------------------------------------------------------

  test "the same seed produces the identical assignment" do
    args = [players(8), questions(25), 3]

    a = apply(Binning, :assign, args ++ [[seed: 42]])
    b = apply(Binning, :assign, args ++ [[seed: 42]])

    assert a == b
  end

  test "different seeds generally produce different assignments" do
    a = Binning.assign(players(8), questions(25), 3, seed: 1)
    b = Binning.assign(players(8), questions(25), 3, seed: 999)

    refute a == b
  end

  test "runs without a seed and still satisfies the core guarantees" do
    assignment = Binning.assign(players(6), questions(20), 3)

    per_player = counts_per_player(assignment)
    assert map_size(per_player) == 6
    for {_pid, count} <- per_player, do: assert(count == 3)
    for {_qid, pids} <- assignment, do: assert(length(pids) >= 2)
  end
end
