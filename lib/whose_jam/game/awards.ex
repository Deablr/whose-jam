defmodule WhoseJam.Game.Awards do
  @moduledoc """
  What a finished game is remembered for, beyond the scores. Pure: plain data
  in, plain data out.

  Five awards, from the rounds that were played to a reveal and from how
  quickly everyone picked their songs:

    * **best bluff** — the song that fooled the most players, and who picked it;
    * **sharpest** — whoever called the most songs correctly;
    * **most fooled** — whoever guessed wrong the most;
    * **slowest vote** — whoever took longest, on average, to lock in once the
      vote opened;
    * **quickest pick** — whoever finished picking all their songs fastest.

  Ties are shared, never broken: every round that fooled the most is a best
  bluff, and everyone on the most correct calls is sharpest. An award nobody
  earned (nobody fooled, nobody right, nobody timed) is `nil`.
  """

  @typedoc """
  One round as it ended: who picked the song, how many players they fooled
  (their fool-points), and which players called it. Optionally, which players
  guessed wrong (`missed`) and how long each voter took to lock in after the
  vote opened, in ms (`vote_ms`).
  """
  @type played_round :: %{
          required(:submitter_id) => String.t(),
          required(:song_name) => String.t(),
          required(:fooled) => non_neg_integer(),
          required(:called) => [String.t()],
          optional(:missed) => [String.t()],
          optional(:vote_ms) => %{String.t() => non_neg_integer()}
        }

  @typedoc """
  How long a player took to pick all their songs, in ms (only players who
  picked every song they were asked for).
  """
  @type pick :: %{player_id: String.t(), ms: non_neg_integer()}

  @typedoc "A timed award: the time, who holds it, and how many were timed."
  @type timed :: %{ms: non_neg_integer(), player_ids: [String.t()], of: pos_integer()}

  @type t :: %{
          best_bluff:
            %{
              fooled: pos_integer(),
              bluffs: [%{player_id: String.t(), song_name: String.t()}]
            }
            | nil,
          sharpest: %{called: pos_integer(), player_ids: [String.t()]} | nil,
          most_fooled: %{missed: pos_integer(), player_ids: [String.t()]} | nil,
          slowest_vote: timed() | nil,
          quickest_pick: timed() | nil
        }

  @doc """
  The awards for `rounds`, given in the order they were played (which is the
  order tied winners are listed in), and the `picks` (see `t:pick/0`).

      iex> rounds = [
      ...>   %{submitter_id: "ava", song_name: "Neon", fooled: 1, called: ["ben", "cleo"]},
      ...>   %{submitter_id: "ben", song_name: "Paper", fooled: 2, called: ["cleo"]}
      ...> ]
      iex> WhoseJam.Game.Awards.summarize(rounds)
      %{
        best_bluff: %{fooled: 2, bluffs: [%{player_id: "ben", song_name: "Paper"}]},
        sharpest: %{called: 2, player_ids: ["cleo"]},
        most_fooled: nil,
        slowest_vote: nil,
        quickest_pick: nil
      }
  """
  @spec summarize([played_round()], [pick()]) :: t()
  def summarize(rounds, picks \\ []) do
    %{
      best_bluff: best_bluff(rounds),
      sharpest: most(rounds, :called, :called),
      most_fooled: most(rounds, :missed, :missed),
      slowest_vote: slowest_vote(rounds),
      quickest_pick: quickest_pick(picks)
    }
  end

  @doc """
  Whether an award from `summarize/2` singles somebody out, so a screen hands
  it out. A counted award (best bluff, sharpest, most fooled) must have been
  earned more than once (more than one player fooled, more than one song
  called or missed); a timed one (slowest vote, quickest pick) must have been
  won among at least three players. Either way at most two players hold it
  (an award half the room shares singles nobody out). Several tied songs of
  one player's are one holder.

      iex> WhoseJam.Game.Awards.given?(%{fooled: 2, bluffs: [%{player_id: "ava", song_name: "Neon"}]})
      true
      iex> WhoseJam.Game.Awards.given?(%{called: 1, player_ids: ["ben"]})
      false
      iex> WhoseJam.Game.Awards.given?(%{ms: 4_000, player_ids: ["ben"], of: 3})
      true
  """
  @spec given?(map() | nil) :: boolean()
  def given?(%{fooled: fooled, bluffs: bluffs}),
    do: fooled > 1 and holders(Enum.map(bluffs, & &1.player_id)) <= 2

  def given?(%{called: called, player_ids: ids}), do: called > 1 and holders(ids) <= 2
  def given?(%{missed: missed, player_ids: ids}), do: missed > 1 and holders(ids) <= 2
  def given?(%{ms: _ms, player_ids: ids, of: of}), do: of >= 3 and holders(ids) <= 2
  def given?(nil), do: false

  defp holders(ids), do: ids |> Enum.uniq() |> length()

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

  # Whoever is listed under `field` (`:called` or `:missed`) in the most
  # rounds, keeping the order in which each was first listed.
  defp most(rounds, field, key) do
    listed = Enum.flat_map(rounds, &Map.get(&1, field, []))
    counts = Enum.frequencies(listed)

    case counts |> Map.values() |> Enum.max(fn -> 0 end) do
      0 ->
        nil

      top ->
        %{key => top, :player_ids => listed |> Enum.uniq() |> Enum.filter(&(counts[&1] == top))}
    end
  end

  # Each voter's average time to lock in, over the rounds they voted in.
  defp slowest_vote(rounds) do
    averages =
      rounds
      |> Enum.flat_map(&Map.to_list(Map.get(&1, :vote_ms, %{})))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {id, times} -> {id, div(Enum.sum(times), length(times))} end)

    timed(averages, &Enum.max/1, voter_order(rounds))
  end

  defp quickest_pick(picks) do
    timed(Enum.map(picks, &{&1.player_id, &1.ms}), &Enum.min/1, Enum.map(picks, & &1.player_id))
  end

  defp timed([], _best, _order), do: nil

  defp timed(times, best, order) do
    by_id = Map.new(times)
    top = by_id |> Map.values() |> best.()

    %{
      ms: top,
      player_ids: order |> Enum.uniq() |> Enum.filter(&(by_id[&1] == top)),
      of: map_size(by_id)
    }
  end

  # Voters in the order they first voted in a round, then by id within one.
  defp voter_order(rounds),
    do: Enum.flat_map(rounds, &(&1 |> Map.get(:vote_ms, %{}) |> Map.keys() |> Enum.sort()))
end
