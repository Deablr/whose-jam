defmodule WhoseJam.Game.Config do
  @moduledoc """
  Pure timing/settings for a game, derived from player count plus host
  overrides.

  Nothing here touches a process, the Repo, or any external service: it takes
  plain data in (an overrides map and a player count) and returns a `%Config{}`
  struct out. The struct fully determines the pacing of a session, and
  `estimated_runtime_s/2` turns it back into a wall-clock estimate.

  ## Fields

  Host-facing (exposed as settings, per the PRD):

    * `answer_timer_s` — global answer phase length, in seconds. Defaults to
      `questions_per_player * #{30}s` (more songs to submit ⇒ more time).
    * `vote_timer_s` — per-round voting window, in seconds. Defaults to `30`.
    * `questions_per_player` — songs each player submits. Default is tuned per
      player count so the estimated runtime lands near the 20-minute target
      (fewer questions at higher player counts, since every submitted song adds
      a play-and-vote round).
    * `subrounds_enabled?` — split a multi-style theme into one sub-round per
      style. Defaults to `true`.
    * `allow_vote_change?` — let voters change a cast vote. Defaults to `false`.

  Internal (used only by the runtime estimator; documented here because they
  shape `estimated_runtime_s/2`). All default to fixed values and are rarely
  overridden, but `build/2` accepts overrides for them too:

    * `song_playback_s` — seconds of song audio played per round. Default `30`.
    * `reveal_padding_s` — pause to reveal the submitter each round. Default `5`.
    * `results_padding_s` — pause on the running scoreboard each round.
      Default `5`.
  """

  @answer_s_per_question 30
  @default_vote_timer_s 30
  @default_song_playback_s 30
  @default_reveal_padding_s 5
  @default_results_padding_s 5

  @type t :: %__MODULE__{
          answer_timer_s: pos_integer(),
          vote_timer_s: pos_integer(),
          questions_per_player: pos_integer(),
          subrounds_enabled?: boolean(),
          allow_vote_change?: boolean(),
          song_playback_s: non_neg_integer(),
          reveal_padding_s: non_neg_integer(),
          results_padding_s: non_neg_integer()
        }

  defstruct answer_timer_s: nil,
            vote_timer_s: @default_vote_timer_s,
            questions_per_player: nil,
            subrounds_enabled?: true,
            allow_vote_change?: false,
            song_playback_s: @default_song_playback_s,
            reveal_padding_s: @default_reveal_padding_s,
            results_padding_s: @default_results_padding_s

  @doc """
  Build a `%Config{}` from host `overrides` and the current `player_count`.

  Defaults are derived from `player_count`; any host override wins. Overrides
  may use atom or string keys (LiveView forms send strings), and string values
  are coerced for known fields (`"45"` → `45`, `"true"` → `true`).

  Resolution order matters: `questions_per_player` is resolved first, then
  `answer_timer_s` derives from the resolved value unless the host overrode it
  directly.
  """
  @spec build(map(), pos_integer()) :: t()
  def build(overrides, player_count)
      when is_map(overrides) and is_integer(player_count) and player_count > 0 do
    qpp =
      fetch_int(overrides, :questions_per_player, default_questions_per_player(player_count))

    answer_timer_s =
      fetch_int(overrides, :answer_timer_s, qpp * @answer_s_per_question)

    %__MODULE__{
      answer_timer_s: answer_timer_s,
      vote_timer_s: fetch_int(overrides, :vote_timer_s, @default_vote_timer_s),
      questions_per_player: qpp,
      subrounds_enabled?: fetch_bool(overrides, :subrounds_enabled?, true),
      allow_vote_change?: fetch_bool(overrides, :allow_vote_change?, false),
      song_playback_s: fetch_int(overrides, :song_playback_s, @default_song_playback_s),
      reveal_padding_s: fetch_int(overrides, :reveal_padding_s, @default_reveal_padding_s),
      results_padding_s: fetch_int(overrides, :results_padding_s, @default_results_padding_s)
    }
  end

  @doc """
  Estimate the total wall-clock length of a game, in seconds.

  Model: a single answer phase, then one round per submitted song. Each round
  is a song snippet + a voting window + reveal/results padding. Round count is
  `player_count * questions_per_player`, since every submitted song becomes its
  own play-and-vote round.

  This is a theme-agnostic estimate; it treats answering as one phase even when
  sub-rounds are enabled (the config carries no theme structure).
  """
  @spec estimated_runtime_s(t(), pos_integer()) :: non_neg_integer()
  def estimated_runtime_s(%__MODULE__{} = config, player_count)
      when is_integer(player_count) and player_count > 0 do
    round_count = player_count * config.questions_per_player

    per_round_s =
      config.song_playback_s + config.vote_timer_s + config.reveal_padding_s +
        config.results_padding_s

    config.answer_timer_s + per_round_s * round_count
  end

  # Keep total round count near ~15-16 so the estimate stays within ±20% of the
  # 20-minute target across 3..8 players. Never below 2 questions per player.
  @spec default_questions_per_player(pos_integer()) :: pos_integer()
  defp default_questions_per_player(player_count) do
    max(2, round(15 / player_count))
  end

  # --- override helpers: atom-or-string key lookup + value coercion ---

  defp fetch_int(overrides, key, default) do
    case fetch_raw(overrides, key) do
      :error -> default
      {:ok, value} -> to_int(value, default)
    end
  end

  defp fetch_bool(overrides, key, default) do
    case fetch_raw(overrides, key) do
      :error -> default
      {:ok, value} -> to_bool(value, default)
    end
  end

  defp fetch_raw(overrides, key) do
    case Map.fetch(overrides, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(overrides, Atom.to_string(key))
    end
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp to_int(_value, default), do: default

  defp to_bool(value, _default) when is_boolean(value), do: value

  defp to_bool(value, _default) when is_binary(value) do
    String.trim(value) in ["true", "on", "1"]
  end

  defp to_bool(_value, default), do: default
end
