defmodule WhoseJam.Game.Config do
  @moduledoc """
  Pure timing/settings for a game, derived from player count plus host
  overrides.

  Nothing here touches a process, the Repo, or any external service: it takes
  plain data in (an overrides map and a player count) and returns a `%Config{}`
  struct out. The struct fully determines the pacing of a session, and
  `estimated_runtime_s/3` turns it back into a wall-clock estimate.

  ## Fields

  Host-facing (exposed as settings, per the PRD):

    * `answer_s_per_question` — seconds each player gets per question they are
      asked, so the answer phase lasts `answer_s_per_question *
      questions_per_player` (per style in a sub-round; see `answer_window_s/2`).
      Defaults to `45`.
    * `vote_delay_s` — seconds the song plays before voting opens. Defaults to
      `10`; `0` opens voting as soon as the song starts.
    * `vote_timer_s` — the voting countdown, in seconds. It starts once a
      majority of eligible voters have voted (or the song ends) and drops to a
      short final countdown once everyone has voted (3s, or 5s when votes can
      be changed; `Game.Server` constants). Defaults to `60`.
    * `questions_per_player` — songs each player submits. Default is tuned per
      player count so the estimated runtime lands near the 20-minute target
      (fewer questions at higher player counts, since every submitted song adds
      a play-and-vote round).
    * `subrounds_enabled?` — split a multi-style theme into one sub-round per
      style. Defaults to `true`.
    * `allow_vote_change?` — let voters change a cast vote. Defaults to `false`.
    * `min_players` — players needed before the host can start. Defaults to
      `3` (so guessing is non-trivial); can be lowered to `2` for development
      and small groups. Clamped to `2..8` (see `min_players_range/0`).

  Host-facing scoring switches (each defaults to `true`; `Game.Scoring` takes
  them as `scoring_opts/1`):

    * `score_correct?` — +1 to a voter who guessed right.
    * `score_fooled?` — +1 to a picker for each player their song fooled.
    * `score_predictions?` — +1 to a picker whose blame prediction came true.
      Switched off, the picker isn't asked to predict at all.

  Host-facing presentation choices (how the screens tell the game; they never
  change the scoring or the timers):

    * `quick_reveals?` — each reveal lands all at once, and the winner's
      moment is short, instead of in staged beats. Defaults to `false`.
    * `name_non_voters?` — the reveal names who let the clock run out ("1
      didn't vote · Ava") rather than only counting them. Defaults to `true`.
    * `show_places?` — every seat in the TV's score strip shows its place
      ("2nd"), not only the leader's outline. Defaults to `false`.
    * `final_suspense?` — the game's last reveal shows only what the round
      was worth, keeping the totals for the final scores. Defaults to `true`.

  Every integer override is clamped to a safe range, so a hand-crafted
  `set_config` can never produce a negative or timer-overflowing value:
  `answer_s_per_question` `1..300`, `vote_delay_s` `0..60`, `vote_timer_s` `1..300`,
  `questions_per_player` `1..10`, `min_players` `2..8` (see `range/1`). The
  derived `questions_per_player` default is clamped into its range too.

  Internal (fixed values that shape `estimated_runtime_s/3`; `song_playback_s`
  also sizes the server's voting safety timeout). They are **not** overridable
  via `build/2` — only the fourteen host-facing settings above can be overridden:

    * `song_playback_s` — typical listening time before most votes are in.
      Default `30`.
    * `reveal_padding_s` — pause to reveal the submitter each round. Default `5`.
    * `results_padding_s` — pause on the running scoreboard each round.
      Default `5`.
  """

  @default_answer_s_per_question 45
  @default_vote_timer_s 60
  @default_vote_delay_s 10
  @default_song_playback_s 30
  @default_reveal_padding_s 5
  @default_results_padding_s 5
  @default_min_players 3
  @min_players_range 2..8
  @answer_s_per_question_range 1..300
  @vote_delay_range 0..60
  @vote_timer_range 1..300
  @questions_per_player_range 1..10

  @type t :: %__MODULE__{
          answer_s_per_question: pos_integer(),
          vote_timer_s: pos_integer(),
          vote_delay_s: non_neg_integer(),
          questions_per_player: pos_integer(),
          subrounds_enabled?: boolean(),
          allow_vote_change?: boolean(),
          min_players: pos_integer(),
          quick_reveals?: boolean(),
          name_non_voters?: boolean(),
          show_places?: boolean(),
          final_suspense?: boolean(),
          score_correct?: boolean(),
          score_fooled?: boolean(),
          score_predictions?: boolean(),
          song_playback_s: non_neg_integer(),
          reveal_padding_s: non_neg_integer(),
          results_padding_s: non_neg_integer()
        }

  defstruct answer_s_per_question: @default_answer_s_per_question,
            vote_timer_s: @default_vote_timer_s,
            vote_delay_s: @default_vote_delay_s,
            questions_per_player: nil,
            subrounds_enabled?: true,
            allow_vote_change?: false,
            min_players: @default_min_players,
            quick_reveals?: false,
            name_non_voters?: true,
            show_places?: false,
            final_suspense?: true,
            score_correct?: true,
            score_fooled?: true,
            score_predictions?: true,
            song_playback_s: @default_song_playback_s,
            reveal_padding_s: @default_reveal_padding_s,
            results_padding_s: @default_results_padding_s

  @doc """
  Build a `%Config{}` from host `overrides` and the current `player_count`.

  Defaults are derived from `player_count`; any host override wins. Overrides
  may use atom or string keys (LiveView forms send strings), and string values
  are coerced for known fields (`"45"` → `45`, `"true"` → `true`).

  Only the fourteen host-facing settings can be overridden (`answer_s_per_question`,
  `vote_timer_s`, `vote_delay_s`, `questions_per_player`, `subrounds_enabled?`,
  `allow_vote_change?`, `min_players`, `quick_reveals?`, `name_non_voters?`,
  `show_places?`, `final_suspense?`, `score_correct?`, `score_fooled?`,
  `score_predictions?`); any other key in `overrides` is ignored. The internal
  estimator fields stay fixed at their constant defaults. Integer overrides are
  clamped to the ranges listed in the moduledoc.

  """
  @spec build(map(), pos_integer()) :: t()
  def build(overrides, player_count)
      when is_map(overrides) and is_integer(player_count) and player_count > 0 do
    qpp =
      fetch_int(
        overrides,
        :questions_per_player,
        default_questions_per_player(player_count),
        @questions_per_player_range
      )

    %__MODULE__{
      answer_s_per_question:
        fetch_int(
          overrides,
          :answer_s_per_question,
          @default_answer_s_per_question,
          @answer_s_per_question_range
        ),
      vote_timer_s: fetch_int(overrides, :vote_timer_s, @default_vote_timer_s, @vote_timer_range),
      vote_delay_s: fetch_int(overrides, :vote_delay_s, @default_vote_delay_s, @vote_delay_range),
      questions_per_player: qpp,
      subrounds_enabled?: fetch_bool(overrides, :subrounds_enabled?, true),
      allow_vote_change?: fetch_bool(overrides, :allow_vote_change?, false),
      min_players: fetch_int(overrides, :min_players, @default_min_players, @min_players_range),
      quick_reveals?: fetch_bool(overrides, :quick_reveals?, false),
      name_non_voters?: fetch_bool(overrides, :name_non_voters?, true),
      show_places?: fetch_bool(overrides, :show_places?, false),
      final_suspense?: fetch_bool(overrides, :final_suspense?, true),
      score_correct?: fetch_bool(overrides, :score_correct?, true),
      score_fooled?: fetch_bool(overrides, :score_fooled?, true),
      score_predictions?: fetch_bool(overrides, :score_predictions?, true),
      song_playback_s: @default_song_playback_s,
      reveal_padding_s: @default_reveal_padding_s,
      results_padding_s: @default_results_padding_s
    }
  end

  @doc """
  Estimate the total wall-clock length of a game, in seconds.

  Model: one answer phase per sub-round, then one round per submitted song.
  Each round is listening time before most votes are in (at least the vote
  delay) + half the voting countdown (it rarely runs in full: it drops to a
  few seconds once everyone has voted) + reveal/results padding.
  Round count is `player_count * questions_per_player` (total across all
  sub-rounds), since every submitted song becomes its own play-and-vote round.

  `subround_count` (default `1`) is the number of styles the theme plays.
  Every style asks each player `questions_per_player` questions, so the
  answering time is `answer_window_s/1` once per style whether the styles are
  split into sub-rounds or collapsed into one phase. Only the answering
  multiplies — the total round count is unchanged.

  The arity-2 form is equivalent to `subround_count = 1`.
  """
  @spec estimated_runtime_s(t(), pos_integer(), pos_integer()) :: non_neg_integer()
  def estimated_runtime_s(config, player_count, subround_count \\ 1)

  def estimated_runtime_s(%__MODULE__{} = config, player_count, subround_count)
      when is_integer(player_count) and player_count > 0 and
             is_integer(subround_count) and subround_count > 0 do
    round_count = player_count * config.questions_per_player

    per_round_s =
      max(config.song_playback_s, config.vote_delay_s) + div(config.vote_timer_s, 2) +
        config.reveal_padding_s + config.results_padding_s

    answer_window_s(config) * subround_count + per_round_s * round_count
  end

  @doc """
  How long one style's answer phase lasts, in seconds: every player is asked
  `questions_per_player` questions and gets `answer_s_per_question` for each.
  (A collapsed sub-round covering several styles gets this once per style.)
  """
  @spec answer_window_s(t()) :: pos_integer()
  def answer_window_s(%__MODULE__{} = config),
    do: config.answer_s_per_question * config.questions_per_player

  @doc """
  The scoring switches as the options `WhoseJam.Game.Scoring.score_round/3`
  takes.
  """
  @spec scoring_opts(t()) :: %{
          correct?: boolean(),
          fooled?: boolean(),
          predictions?: boolean()
        }
  def scoring_opts(%__MODULE__{} = config) do
    %{
      correct?: config.score_correct?,
      fooled?: config.score_fooled?,
      predictions?: config.score_predictions?
    }
  end

  @doc """
  The clamp range for a host-facing integer setting.

  `key` is one of `:answer_s_per_question`, `:vote_delay_s`, `:vote_timer_s`,
  `:questions_per_player`, or `:min_players`. Overrides outside the range are
  clamped to its nearest edge by `build/2`.
  """
  @spec range(atom()) :: Range.t()
  def range(:answer_s_per_question), do: @answer_s_per_question_range
  def range(:vote_delay_s), do: @vote_delay_range
  def range(:vote_timer_s), do: @vote_timer_range
  def range(:questions_per_player), do: @questions_per_player_range
  def range(:min_players), do: @min_players_range

  @doc """
  The range `min_players` is clamped to (also the choices offered to the host).
  Equivalent to `range(:min_players)`.
  """
  @spec min_players_range() :: Range.t()
  def min_players_range, do: range(:min_players)

  # Keep total round count near ~15-16 so the estimate stays within ±20% of the
  # 20-minute target across 3..8 players. Never below 2 questions per player,
  # and always inside the `questions_per_player` clamp range (e.g. a 1-player
  # count would otherwise derive 15).
  @spec default_questions_per_player(pos_integer()) :: pos_integer()
  defp default_questions_per_player(player_count) do
    first..last//_ = @questions_per_player_range
    (15 / player_count) |> round() |> max(2) |> max(first) |> min(last)
  end

  # --- override helpers: atom-or-string key lookup + value coercion ---

  # An override is coerced and clamped to `range`; the derived default is used
  # as-is when the key is absent.
  defp fetch_int(overrides, key, default, first..last//_) do
    case fetch_raw(overrides, key) do
      :error -> default
      {:ok, value} -> value |> to_int(default) |> max(first) |> min(last)
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
