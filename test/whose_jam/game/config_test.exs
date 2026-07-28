defmodule WhoseJam.Game.ConfigTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Game.Config

  @target_s 1200
  @band_low round(@target_s * 0.8)
  @band_high round(@target_s * 1.2)

  describe "build/2 defaults" do
    test "vote timer defaults to 30s" do
      assert Config.build(%{}, 5).vote_timer_s == 30
    end

    test "allow_vote_change? defaults to false and subrounds_enabled? defaults to true" do
      config = Config.build(%{}, 5)
      assert config.allow_vote_change? == false
      assert config.subrounds_enabled? == true
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

    test "answer timer scales with the resolved questions per player" do
      for n <- 3..8 do
        config = Config.build(%{}, n)
        # 30s of answering budget per assigned question.
        assert config.answer_timer_s == config.questions_per_player * 30
      end
    end

    test "derived timings at representative player counts (3, 5, 8)" do
      for n <- [3, 5, 8] do
        config = Config.build(%{}, n)
        assert config.vote_timer_s == 30
        assert config.questions_per_player >= 2
        assert config.answer_timer_s > 0
      end
    end
  end

  describe "build/2 overrides" do
    test "atom-keyed overrides win over defaults" do
      config =
        Config.build(
          %{
            answer_timer_s: 90,
            vote_timer_s: 45,
            questions_per_player: 7,
            subrounds_enabled?: false,
            allow_vote_change?: true
          },
          5
        )

      assert config.answer_timer_s == 90
      assert config.vote_timer_s == 45
      assert config.questions_per_player == 7
      assert config.subrounds_enabled? == false
      assert config.allow_vote_change? == true
    end

    test "string-keyed overrides (as LiveView forms send) win over defaults" do
      config =
        Config.build(
          %{
            "answer_timer_s" => 90,
            "vote_timer_s" => 45,
            "questions_per_player" => 7,
            "subrounds_enabled?" => false,
            "allow_vote_change?" => true
          },
          5
        )

      assert config.answer_timer_s == 90
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

    test "answer timer follows an overridden questions_per_player when not set directly" do
      config = Config.build(%{questions_per_player: 8}, 4)
      assert config.questions_per_player == 8
      assert config.answer_timer_s == 8 * 30
    end

    test "a direct answer_timer_s override beats the questions-per-player derivation" do
      config = Config.build(%{questions_per_player: 8, answer_timer_s: 60}, 4)
      assert config.answer_timer_s == 60
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

    test "cranking up questions_per_player lengthens the game (no cap)" do
      base = Config.build(%{}, 5)
      cranked = Config.build(%{questions_per_player: 20}, 5)

      base_runtime = Config.estimated_runtime_s(base, 5)
      cranked_runtime = Config.estimated_runtime_s(cranked, 5)

      assert cranked_runtime > base_runtime
      # 20 questions × 5 players is far past the 20-minute window — that's fine.
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
      slower = Config.build(%{vote_timer_s: 60}, 5)
      assert Config.estimated_runtime_s(slower, 5) > Config.estimated_runtime_s(base, 5)
    end

    test "arity-2 form equals subround_count = 1" do
      config = Config.build(%{}, 5)
      assert Config.estimated_runtime_s(config, 5) == Config.estimated_runtime_s(config, 5, 1)
    end

    test "with sub-rounds enabled, each extra sub-round adds exactly one answer phase" do
      config = Config.build(%{subrounds_enabled?: true}, 5)

      one = Config.estimated_runtime_s(config, 5, 1)
      two = Config.estimated_runtime_s(config, 5, 2)

      assert two - one == config.answer_timer_s
      # Only the answer phases multiply; the round count (and thus per-round
      # time) is unchanged, so the delta is exactly one answer phase.
      assert two == one + config.answer_timer_s
    end

    test "with sub-rounds disabled, subround_count is ignored" do
      config = Config.build(%{subrounds_enabled?: false}, 5)

      assert Config.estimated_runtime_s(config, 5, 3) ==
               Config.estimated_runtime_s(config, 5, 1)
    end
  end
end
