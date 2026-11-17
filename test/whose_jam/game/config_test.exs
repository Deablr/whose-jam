defmodule WhoseJam.Game.ConfigTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Game.Config

  @target_s 1200
  @band_low round(@target_s * 0.8)
  @band_high round(@target_s * 1.2)

  describe "build/2 defaults" do
    test "vote timer defaults to 60s" do
      assert Config.build(%{}, 5).vote_timer_s == 60
    end

    test "allow_vote_change? defaults to false and subrounds_enabled? defaults to true" do
      config = Config.build(%{}, 5)
      assert config.allow_vote_change? == false
      assert config.subrounds_enabled? == true
    end

    test "presentation choices default to the staged, named, place-free, suspenseful game" do
      config = Config.build(%{}, 5)
      assert config.quick_reveals? == false
      assert config.name_non_voters? == true
      assert config.show_places? == false
      assert config.final_suspense? == true
    end

    test "derives fewer questions per player as player count grows" do
      qpp = fn n -> Config.build(%{}, n).questions_per_player end

      # More players ⇒ more rounds per question, so defaults trend downward.
      assert qpp.(3) >= qpp.(8)
      assert qpp.(3) > qpp.(8)

      for n <- 3..8 do
        assert qpp.(n) >= 2, "expected at least 2 questions per player at #{n} players"
      end
    end

    test "each question gets 45 seconds, so the answer phase scales with the questions per player" do
      for n <- 3..8 do
        config = Config.build(%{}, n)
        assert config.answer_s_per_question == 45
        assert Config.answer_window_s(config) == config.questions_per_player * 45
      end
    end

    test "the vote countdown defaults to a minute" do
      assert Config.build(%{}, 5).vote_timer_s == 60
    end

    test "every way of scoring is on unless switched off" do
      config = Config.build(%{}, 5)
      assert Config.scoring_opts(config) == %{correct?: true, fooled?: true, predictions?: true}

      off =
        Config.build(
          %{"score_fooled?" => "false", score_correct?: false, score_predictions?: false},
          5
        )

      assert Config.scoring_opts(off) == %{correct?: false, fooled?: false, predictions?: false}
    end

    test "derived timings at representative player counts (3, 5, 8)" do
      for n <- [3, 5, 8] do
        config = Config.build(%{}, n)
        assert config.vote_timer_s == 60
        assert config.questions_per_player >= 2
        assert config.answer_s_per_question > 0
      end
    end
  end

  describe "build/2 overrides" do
    test "each presentation choice can be flipped, from a form's strings too" do
      flipped = %{
        "quick_reveals?" => "true",
        "name_non_voters?" => "false",
        "show_places?" => "true",
        "final_suspense?" => "false"
      }

      config = Config.build(flipped, 5)
      assert config.quick_reveals? == true
      assert config.name_non_voters? == false
      assert config.show_places? == true
      assert config.final_suspense? == false

      # One at a time: each key drives only its own field.
      for {key, value} <- flipped do
        field = String.to_existing_atom(key)
        config = Config.build(%{key => value}, 5)
        assert Map.fetch!(config, field) == (value == "true")
      end
    end

    test "atom-keyed overrides win over defaults" do
      config =
        Config.build(
          %{
            answer_s_per_question: 90,
            vote_timer_s: 45,
            questions_per_player: 7,
            subrounds_enabled?: false,
            allow_vote_change?: true
          },
          5
        )

      assert config.answer_s_per_question == 90
      assert config.vote_timer_s == 45
      assert config.questions_per_player == 7
      assert config.subrounds_enabled? == false
      assert config.allow_vote_change? == true
    end

    test "string-keyed overrides (as LiveView forms send) win over defaults" do
      config =
        Config.build(
          %{
            "answer_s_per_question" => 90,
            "vote_timer_s" => 45,
            "questions_per_player" => 7,
            "subrounds_enabled?" => false,
            "allow_vote_change?" => true
          },
          5
        )

      assert config.answer_s_per_question == 90
      assert config.vote_timer_s == 45
      assert config.questions_per_player == 7
      assert config.subrounds_enabled? == false
      assert config.allow_vote_change? == true
    end

    test "string values are coerced for known fields" do
      config =
        Config.build(
          %{
            "vote_timer_s" => "45",
            "questions_per_player" => "6",
            "allow_vote_change?" => "true",
            "subrounds_enabled?" => "false"
          },
          5
        )

      assert config.vote_timer_s == 45
      assert config.questions_per_player == 6
      assert config.allow_vote_change? == true
      assert config.subrounds_enabled? == false
    end

    test "the answer window follows an overridden questions_per_player" do
      config = Config.build(%{questions_per_player: 8}, 4)
      assert config.questions_per_player == 8
      assert Config.answer_window_s(config) == 8 * 45
    end

    test "an answer_s_per_question override sets the time for each question" do
      config = Config.build(%{questions_per_player: 8, answer_s_per_question: 60}, 4)
      assert config.answer_s_per_question == 60
      assert Config.answer_window_s(config) == 8 * 60
    end

    test "vote_delay_s defaults to 10, is overridable, and never goes negative" do
      assert Config.build(%{}, 5).vote_delay_s == 10
      assert Config.build(%{"vote_delay_s" => "0"}, 5).vote_delay_s == 0
      assert Config.build(%{vote_delay_s: -4}, 5).vote_delay_s == 0
    end

    test "the all-voted countdown is not a config field and cannot be overridden" do
      refute Map.has_key?(Config.build(%{all_voted_countdown_s: 99}, 5), :all_voted_countdown_s)
    end

    test "min_players defaults to 3 and can be lowered to 2" do
      assert Config.build(%{}, 5).min_players == 3
      assert Config.build(%{min_players: 2}, 5).min_players == 2
      assert Config.build(%{"min_players" => "2"}, 5).min_players == 2
    end

    test "min_players is clamped to 2..8" do
      assert Config.build(%{min_players: 1}, 5).min_players == 2
      assert Config.build(%{min_players: 0}, 5).min_players == 2
      assert Config.build(%{min_players: 12}, 5).min_players == 8
    end

    test "min_players_range/0 exposes the clamp range" do
      assert Config.min_players_range() == 2..8
    end

    test "timer and volume overrides are clamped to safe ranges" do
      low =
        Config.build(
          %{
            answer_s_per_question: -5,
            vote_delay_s: -4,
            vote_timer_s: -5,
            questions_per_player: -1
          },
          5
        )

      assert low.answer_s_per_question == 1
      assert low.vote_delay_s == 0
      assert low.vote_timer_s == 1
      assert low.questions_per_player == 1

      huge = 5_000_000_000

      high =
        Config.build(
          %{
            "answer_s_per_question" => "#{huge}",
            "vote_delay_s" => huge,
            "vote_timer_s" => huge,
            "questions_per_player" => huge
          },
          5
        )

      assert high.answer_s_per_question == 300
      assert high.vote_delay_s == 60
      assert high.vote_timer_s == 300
      assert high.questions_per_player == 10
    end

    test "range/1 exposes each host-facing integer clamp range" do
      assert Config.range(:answer_s_per_question) == 1..300
      assert Config.range(:vote_delay_s) == 0..60
      assert Config.range(:vote_timer_s) == 1..300
      assert Config.range(:questions_per_player) == 1..10
      assert Config.range(:min_players) == 2..8
      assert Config.min_players_range() == Config.range(:min_players)
    end

    test "range edges are kept and their out-of-range neighbours are clamped" do
      for key <- [
            :answer_s_per_question,
            :vote_delay_s,
            :vote_timer_s,
            :questions_per_player,
            :min_players
          ],
          first..last//_ = Config.range(key),
          {input, expected} <- [
            {first, first},
            {last, last},
            {first - 1, first},
            {last + 1, last}
          ] do
        assert Map.fetch!(Config.build(%{key => input}, 5), key) == expected,
               "#{key}: #{input} should resolve to #{expected}"
      end
    end

    test "the derived questions_per_player default stays inside its clamp range" do
      for n <- 1..20 do
        assert Config.build(%{}, n).questions_per_player in Config.range(:questions_per_player)
      end

      assert Config.build(%{}, 1).questions_per_player == 10
    end

    test "the answer window follows the clamped questions_per_player" do
      config = Config.build(%{questions_per_player: 99}, 5)
      assert Config.answer_window_s(config) == 10 * 45
    end

    test "internal estimator fields are not overridable and stay at their constant defaults" do
      config =
        Config.build(
          %{song_playback_s: 999, reveal_padding_s: 999, results_padding_s: 999},
          5
        )

      assert config.song_playback_s == 30
      assert config.reveal_padding_s == 5
      assert config.results_padding_s == 5
    end
  end

  describe "estimated_runtime_s/2" do
    test "defaults land within ±20% of the 20-minute target for every player count 3..8" do
      for n <- 3..8 do
        runtime = Config.estimated_runtime_s(Config.build(%{}, n), n)

        assert runtime >= @band_low and runtime <= @band_high,
               "#{n} players: #{runtime}s is outside #{@band_low}..#{@band_high}s"
      end
    end

    test "returns a non-negative integer" do
      runtime = Config.estimated_runtime_s(Config.build(%{}, 5), 5)
      assert is_integer(runtime)
      assert runtime >= 0
    end

    test "cranking up questions_per_player lengthens the game past the target" do
      base = Config.build(%{}, 5)
      cranked = Config.build(%{questions_per_player: 10}, 5)

      base_runtime = Config.estimated_runtime_s(base, 5)
      cranked_runtime = Config.estimated_runtime_s(cranked, 5)

      assert cranked_runtime > base_runtime
      # 10 questions × 5 players is far past the 20-minute window — that's fine.
      assert cranked_runtime > @band_high
    end

    test "more players means more rounds and a longer game at a fixed questions_per_player" do
      config = %{questions_per_player: 3}
      short = Config.estimated_runtime_s(Config.build(config, 3), 3)
      long = Config.estimated_runtime_s(Config.build(config, 8), 8)
      assert long > short
    end

    test "a longer vote timer lengthens the estimate" do
      base = Config.build(%{}, 5)
      slower = Config.build(%{vote_timer_s: 120}, 5)
      assert Config.estimated_runtime_s(slower, 5) > Config.estimated_runtime_s(base, 5)
    end

    test "a vote delay longer than the typical listening time lengthens each round" do
      base = Config.build(%{}, 5)
      rounds = 5 * base.questions_per_player

      # Up to song_playback_s (30s) the delay overlaps the listening time.
      assert Config.estimated_runtime_s(Config.build(%{vote_delay_s: 20}, 5), 5) ==
               Config.estimated_runtime_s(base, 5)

      # Beyond it, every round grows by the excess.
      assert Config.estimated_runtime_s(Config.build(%{vote_delay_s: 60}, 5), 5) ==
               Config.estimated_runtime_s(base, 5) + 30 * rounds
    end

    test "arity-2 form equals subround_count = 1" do
      config = Config.build(%{}, 5)
      assert Config.estimated_runtime_s(config, 5) == Config.estimated_runtime_s(config, 5, 1)
    end

    test "each extra style adds exactly one answering window" do
      config = Config.build(%{subrounds_enabled?: true}, 5)

      one = Config.estimated_runtime_s(config, 5, 1)
      two = Config.estimated_runtime_s(config, 5, 2)

      # Only the answering multiplies; the round count (and thus per-round
      # time) is unchanged.
      assert two - one == Config.answer_window_s(config)
    end

    test "sub-rounds on or off, the answering takes as long in all" do
      on = Config.build(%{subrounds_enabled?: true}, 5)
      off = Config.build(%{subrounds_enabled?: false}, 5)

      assert Config.estimated_runtime_s(on, 5, 2) == Config.estimated_runtime_s(off, 5, 2)
    end
  end
end
