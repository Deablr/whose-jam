defmodule WhoseJam.Game.Binning do
  @moduledoc """
  Pure question-assignment ("binning") for a sub-round.

  Given the players in a game, the pool of questions for a single style, and a
  per-player target count, `assign/4` produces a map of question id to the list
  of player ids who must submit a song for that question.

  Guarantees (all satisfied when mathematically feasible; degrade gracefully
  otherwise, never crashing):

    * Every player is assigned exactly `questions_per_player` distinct questions.
      When the pool is smaller than the target, a player receives as many
      distinct questions as the pool allows.
    * No player is assigned the same question twice.
    * Every *selected* question has at least two assigned submitters. The
      algorithm deliberately reuses a small set of questions rather than
      spreading submissions thinly across the whole pool, so that voting always
      has more than one candidate submitter per song.

  The module is pure: it performs no process, Repo, or other side effects, and
  is fully deterministic given `opts[:seed]`. Without a seed the shuffle is
  randomized.

  ## Algorithm

  Players and questions are (seeded) shuffled, then a target number of questions
  `k` is chosen — `min(pool, floor(players * per_player / 2))`, floored at the
  per-player count — which keeps every used question at >= 2 submitters while
  maximizing variety. Each player `i` is assigned the `per_player` questions at
  cyclic indices `i * per_player, i * per_player + 1, ...` (mod `k`) of the
  selected set. Because these are consecutive residues of a cycle of length `k`
  (and `per_player <= k`), a player never repeats a question, and the contiguous
  windows distribute the `players * per_player` submissions across the `k`
  questions as evenly as possible.
  """

  @type player_id :: String.t()
  @type question :: %{id: String.t(), prompt: String.t(), style: atom()}

  @doc """
  Assign `questions_per_player` questions from `questions` to each of
  `player_ids`.

  Returns a map of `question_id => [player_id]` containing only the questions
  that were selected. Pass `seed: integer` in `opts` for a deterministic
  assignment.
  """
  @spec assign([player_id()], [question()], pos_integer(), keyword()) :: %{
          String.t() => [player_id()]
        }
  def assign(player_ids, questions, questions_per_player, opts \\ [])
      when is_list(player_ids) and is_list(questions) and is_integer(questions_per_player) do
    state = rand_state(opts)
    {players, state} = shuffled(player_ids, state)
    {pool, _state} = shuffled(questions, state)

    p = length(players)
    pool_size = length(pool)
    per_player = min(questions_per_player, pool_size)

    if p == 0 or per_player <= 0 do
      %{}
    else
      k = target_question_count(p, per_player, pool_size)

      id_by_index =
        pool
        |> Enum.take(k)
        |> Enum.with_index()
        |> Map.new(fn {question, index} -> {index, question.id} end)

      players
      |> Enum.with_index()
      |> Enum.flat_map(fn {player, i} ->
        base = i * per_player

        Enum.map(0..(per_player - 1), fn j ->
          {Map.fetch!(id_by_index, rem(base + j, k)), player}
        end)
      end)
      |> Enum.group_by(fn {qid, _pid} -> qid end, fn {_qid, pid} -> pid end)
    end
  end

  # Number of distinct questions to actually use. Capped at the pool size and at
  # floor(total_slots / 2) so every used question keeps >= 2 submitters, but
  # never below the per-player count (a player needs that many distinct
  # questions). For a single player the >= 2 guarantee is infeasible, so we fall
  # back to the per-player count.
  defp target_question_count(players, per_player, pool_size) do
    ideal = div(players * per_player, 2)

    pool_size
    |> min(ideal)
    |> max(per_player)
  end

  defp rand_state(opts) do
    case Keyword.get(opts, :seed) do
      nil -> :rand.seed_s(:exsss)
      seed when is_integer(seed) -> :rand.seed_s(:exsss, {seed, seed * 2 + 1, seed * 3 + 2})
    end
  end

  # Fisher-Yates-free shuffle that threads the rand state explicitly (no process
  # dictionary), keeping the module side-effect free.
  defp shuffled(list, state) do
    {keyed, state} =
      Enum.map_reduce(list, state, fn element, st ->
        {r, st} = :rand.uniform_s(st)
        {{r, element}, st}
      end)

    shuffled =
      keyed
      |> Enum.sort_by(fn {r, _element} -> r end)
      |> Enum.map(fn {_r, element} -> element end)

    {shuffled, state}
  end
end
