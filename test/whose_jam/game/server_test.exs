defmodule WhoseJam.Game.ServerTest do
  @moduledoc """
  Contract tests for the per-game runtime, exercised entirely through the public
  `WhoseJam.Game` facade — events in, `get_state/1` (and the host/player views)
  out. Internal GenServer state is never inspected directly, per the PRD testing
  philosophy.

  Tests run `async: false` in shared-sandbox mode so the game server process
  (started under the app's DynamicSupervisor) can read seed content through the
  same DB connection.
  """

  use WhoseJam.DataCase, async: false

  alias WhoseJam.Content.{Question, Theme}
  alias WhoseJam.Game

  # The reveal/results pause is shortened globally for tests via the
  # `:results_pause_ms` application env (see config/test.exs), not a per-game
  # override.
  @fast_overrides %{
    questions_per_player: 1,
    answer_timer_s: 1,
    vote_timer_s: 1
  }

  @premium %{access_token: "tok", refresh_token: "ref", expires_at: 0, premium?: true}

  setup do
    # Play-throughs end each round once everyone has voted; shorten that final
    # countdown (normally 5s) so the suite stays fast. Countdown tests that
    # assert the real 5s clear this again.
    put_test_env(:all_voted_countdown_ms, 20)

    # Terminate any game servers left running after each test.
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(WhoseJam.Game.Supervisor) do
        DynamicSupervisor.terminate_child(WhoseJam.Game.Supervisor, pid)
      end
    end)

    :ok
  end

  # --- fixtures -------------------------------------------------------------

  # Set a test-only pacing seam read by Game.Server, restoring the previous
  # value (or absence) when the test exits. `nil` clears it.
  defp put_test_env(key, value) do
    previous = Application.fetch_env(:whose_jam, key)

    if is_nil(value),
      do: Application.delete_env(:whose_jam, key),
      else: Application.put_env(:whose_jam, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:whose_jam, key, v)
        :error -> Application.delete_env(:whose_jam, key)
      end
    end)
  end

  defp insert_theme(style_sequence) do
    %Theme{}
    |> Theme.changeset(%{
      name: "Theme #{System.unique_integer([:positive])}",
      description: "desc",
      style_sequence: style_sequence
    })
    |> Repo.insert!()
  end

  defp insert_questions(theme, style, count) do
    for i <- 1..count do
      %Question{}
      |> Question.changeset(%{
        theme_id: theme.id,
        prompt: "#{style} prompt #{i}",
        style: style,
        is_example: false
      })
      |> Repo.insert!()
    end
  end

  defp guess_who_theme do
    theme = insert_theme([:guess_who])
    insert_questions(theme, :guess_who, 8)
    theme
  end

  # Create a game, join `n` players, verify Spotify Premium, apply fast timers.
  defp lobby_with_players(theme, n, extra_overrides \\ %{}) do
    {:ok, code} = Game.create_game(theme.id, Map.merge(@fast_overrides, extra_overrides))

    ids =
      for i <- 1..n do
        {:ok, %{player_id: id, role: :player}} = Game.join(code, "P#{i}")
        id
      end

    :ok = Game.set_spotify(code, @premium)
    {code, ids}
  end

  # A valid Spotify track URI derived from `tag` (22 alphanumerics).
  defp track_uri(tag) do
    "spotify:track:" <> binary_part(Base.encode16(:crypto.hash(:md5, tag)), 0, 22)
  end

  # The song's `name` is the tag itself, so tests can recover which player
  # submitted the current round's song via `submitter_of/1`.
  defp song(tag), do: %{uri: track_uri(tag), name: tag, artist: "Artist", album_art_url: nil}

  defp submitter_of(view), do: view.round.song.name

  # For a player, submit `song(player_id)` for each assigned question.
  defp submit_all(code, player_id) do
    view = Game.player_view(code, player_id)

    for q <- view.me.assigned do
      :ok = Game.submit_song(code, player_id, q.question_id, song(player_id))
    end

    view.me.assigned
  end

  # Drive a started game to completion by reacting to broadcasts. Voters always
  # vote for the true submitter (identified via the song name we chose = the
  # submitter's id), so scoring is exercised end to end.
  defp play_to_finish(code) do
    receive do
      {:game_state, view} ->
        case {view.phase, view.round_state} do
          {:finished, _} ->
            view

          {:playing, :revealing} ->
            Game.song_ended(code)
            play_to_finish(code)

          {:playing, :voting} ->
            submitter = submitter_of(view)

            for p <- view.players, p.id != submitter, p.id not in view.round.voters do
              Game.cast_vote(code, p.id, submitter)
            end

            play_to_finish(code)

          _ ->
            play_to_finish(code)
        end
    after
      5000 -> flunk("game did not reach :finished")
    end
  end

  # =========================================================================

  describe "lobby & creation" do
    test "create_game returns a code and get_state reports a lobby" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)

      assert is_binary(code)
      assert Game.exists?(code)

      view = Game.get_state(code)
      assert view.phase == :lobby
      assert view.code == code
      assert view.theme.style_sequence == [:guess_who]
      assert view.players == []
      assert view.audience == []
    end

    test "create_game with an unknown theme errors" do
      assert Game.create_game(-1) == {:error, :theme_not_found}
    end

    test "unknown code: reads are nil, commands are not_found" do
      refute Game.exists?("ZZZZ")
      assert Game.get_state("ZZZZ") == nil
      assert Game.join("ZZZZ", "Nobody") == {:error, :not_found}
    end

    test "config overrides are reflected in the public view (lobby only)" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)

      :ok = Game.set_config(code, %{vote_timer_s: 42, questions_per_player: 3})
      view = Game.get_state(code)
      assert view.config.vote_timer_s == 42
      assert view.config.questions_per_player == 3
    end
  end

  describe "joining & capacity" do
    test "the first eight joiners are players; the ninth becomes audience" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)

      for i <- 1..8 do
        assert {:ok, %{role: :player}} = Game.join(code, "P#{i}")
      end

      assert {:ok, %{role: :audience}} = Game.join(code, "Late")

      view = Game.get_state(code)
      assert length(view.players) == 8
      assert length(view.audience) == 1
    end

    test "rejoin restores an existing player's slot; unknown ids error" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)
      {:ok, %{player_id: id, role: :player}} = Game.join(code, "Amy")

      assert Game.rejoin(code, id) == {:ok, %{player_id: id, role: :player}}
      assert Game.rejoin(code, "nope") == {:error, :unknown_player}
    end

    test "joining after the game starts becomes audience (lobby is locked)" do
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)

      assert {:ok, %{role: :audience}} = Game.join(code, "Latecomer")
    end
  end

  describe "start_game guards" do
    test "requires at least three players" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)
      {:ok, _} = Game.join(code, "A")
      {:ok, _} = Game.join(code, "B")
      :ok = Game.set_spotify(code, @premium)

      assert Game.start_game(code) == {:error, :not_enough_players}
    end

    test "min_players lowers the start threshold to two" do
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 2)

      assert Game.get_state(code).config.min_players == 3
      assert Game.start_game(code) == {:error, :not_enough_players}

      :ok = Game.set_config(code, %{"min_players" => "2"})
      assert Game.get_state(code).config.min_players == 2
      assert Game.start_game(code) == :ok
    end

    test "requires Spotify auth and Premium verification" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id, @fast_overrides)
      for i <- 1..3, do: Game.join(code, "P#{i}")

      assert Game.start_game(code) == {:error, :not_authenticated}

      :ok = Game.set_spotify(code, %{access_token: "t", premium?: false})
      assert Game.start_game(code) == {:error, :not_premium}

      :ok = Game.set_spotify(code, @premium)
      assert Game.start_game(code) == :ok
    end
  end

  describe "happy path: lobby -> answering -> playing -> finished" do
    test "a small 3-player guess_who game plays through to a final scoreboard" do
      theme = guess_who_theme()
      {code, [p1, p2, p3]} = lobby_with_players(theme, 3)

      :ok = Game.start_game(code)

      view = Game.get_state(code)
      assert view.phase == :answering
      assert is_integer(view.answering.deadline_ms)
      # Progress counts are exposed; the songs themselves are not.
      assert view.answering.progress[p1] == %{submitted: 0, total: 1}

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      # Each player submits their single assigned question.
      for pid <- [p1, p2, p3], do: submit_all(code, pid)

      final = play_to_finish(code)

      assert final.phase == :finished
      assert final.round == nil
      # Winner(s) are computed and players/audience are kept separate.
      assert is_list(final.winners.players)
      assert final.winners.audience == []
      # Everyone voted correctly every round, so guessers accrued points.
      assert Enum.any?(Map.values(final.scores), &(&1 > 0))
    end

    test "a 2-player game (min_players: 2) plays through to a final scoreboard" do
      theme = guess_who_theme()
      {code, [p1, p2]} = lobby_with_players(theme, 2, %{min_players: 2})

      :ok = Game.start_game(code)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      for pid <- [p1, p2], do: submit_all(code, pid)

      final = play_to_finish(code)

      assert final.phase == :finished
      assert Enum.any?(Map.values(final.scores), &(&1 > 0))
    end

    test "re-submitting before the timer changes the pick (last write wins)" do
      theme = guess_who_theme()
      {code, [p1 | _]} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)

      [q] = Game.player_view(code, p1).me.assigned
      :ok = Game.submit_song(code, p1, q.question_id, song("first"))
      :ok = Game.submit_song(code, p1, q.question_id, song("second"))

      assigned = Game.player_view(code, p1).me.assigned
      assert hd(assigned).song.uri == track_uri("second")
      assert hd(assigned).submitted? == true
    end

    test "only Spotify image-CDN album art URLs are stored; anything else becomes nil" do
      theme = guess_who_theme()
      {code, [p1 | _]} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      [q] = Game.player_view(code, p1).me.assigned

      stored_art = fn url ->
        :ok = Game.submit_song(code, p1, q.question_id, %{song("s") | album_art_url: url})
        hd(Game.player_view(code, p1).me.assigned).song.album_art_url
      end

      valid = "https://i.scdn.co/image/ab67616d0000b273abcdef0123456789"
      assert stored_art.(valid) == valid

      for bad <- [
            "x');z-index:2147483647;background:url('https://attacker/x.png",
            "https://i.scdn.co/image/abc');color:red",
            "http://i.scdn.co/image/abc123",
            "https://attacker.example/image/abc123",
            "javascript:alert(1)",
            123
          ] do
        assert stored_art.(bad) == nil, "expected #{inspect(bad)} to be dropped"
      end
    end

    test "a submission whose uri is not a Spotify track URI is rejected" do
      theme = guess_who_theme()
      {code, [p1 | _]} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      [q] = Game.player_view(code, p1).me.assigned

      for bad <- [
            nil,
            123,
            "",
            "spotify:album:4uLU6hMCjMI75M1A2tKUQC",
            "spotify:track:4uLU6hMCjMI75M1A2tKUQ",
            "spotify:track:4uLU6hMCjMI75M1A2tKUQCx",
            "spotify:track:4uLU6hMCjMI75M1A2tKU-C",
            "spotify:track:4uLU6hMCjMI75M1A2tKUQC\n",
            "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"
          ] do
        assert Game.submit_song(code, p1, q.question_id, %{song("s") | uri: bad}) ==
                 {:error, :invalid_song},
               "expected #{inspect(bad)} to be rejected"
      end

      refute hd(Game.player_view(code, p1).me.assigned).submitted?

      valid = "spotify:track:4uLU6hMCjMI75M1A2tKUQC"
      assert Game.submit_song(code, p1, q.question_id, %{song("s") | uri: valid}) == :ok
      assert hd(Game.player_view(code, p1).me.assigned).song.uri == valid
    end

    test "song name and artist are trimmed, capped at 200 chars, and non-strings become empty" do
      theme = guess_who_theme()
      {code, [p1 | _]} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      [q] = Game.player_view(code, p1).me.assigned

      stored = fn name, artist ->
        :ok =
          Game.submit_song(code, p1, q.question_id, %{song("s") | name: name, artist: artist})

        hd(Game.player_view(code, p1).me.assigned).song
      end

      long = String.duplicate("a", 500)
      song = stored.("  Hey Jude  ", long)
      assert song.name == "Hey Jude"
      assert song.artist == String.duplicate("a", 200)

      song = stored.(%{evil: true}, nil)
      assert song.name == ""
      assert song.artist == ""
    end
  end

  describe "voting rules" do
    # Bring a game to the point where round 0 is open for voting.
    defp start_voting(theme) do
      {code, ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      for pid <- ids, do: submit_all(code, pid)
      # Answering ended early (all submitted) -> playing/:revealing.
      :ok = Game.song_ended(code)

      view = Game.get_state(code)
      assert view.round_state == :voting
      {code, view}
    end

    test "the submitter cannot vote in their own round" do
      theme = guess_who_theme()
      {code, view} = start_voting(theme)

      submitter = submitter_of(view)
      assert Game.cast_vote(code, submitter, submitter) == {:error, :own_round}
    end

    test "double voting is rejected unless allow_vote_change? is enabled" do
      theme = guess_who_theme()
      {code, view} = start_voting(theme)

      submitter = submitter_of(view)
      voter = Enum.find(view.players, &(&1.id != submitter)).id
      other = Enum.find(view.players, &(&1.id != submitter and &1.id != voter)).id

      assert Game.cast_vote(code, voter, submitter) == :ok
      # Second vote by the same voter is rejected...
      assert Game.cast_vote(code, voter, other) == {:error, :already_voted}
    end

    test "with allow_vote_change? enabled a voter may change their vote" do
      theme = guess_who_theme()
      {code, ids} = lobby_with_players(theme, 3, %{allow_vote_change?: true})
      :ok = Game.start_game(code)
      for pid <- ids, do: submit_all(code, pid)
      :ok = Game.song_ended(code)

      view = Game.get_state(code)
      submitter = submitter_of(view)
      [a, b] = for p <- view.players, p.id != submitter, do: p.id

      assert Game.cast_vote(code, a, submitter) == :ok
      # Changing to another candidate is allowed here.
      assert Game.cast_vote(code, a, b) == :ok
    end

    test "the round advances when the vote timer expires with missing votes" do
      theme = guess_who_theme()
      {code, _view} = start_voting(theme)

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      # Nobody votes; the ~1s vote timer must still move the round to :results,
      # then auto-advance. No points are awarded for the un-voted round.
      assert_receive {:game_state, %{round_state: :results, round: round}}, 2500
      assert round.revealed == true
      assert round.deltas == %{}
    end
  end

  # Answering ends early once everyone submits, leaving round 0 :revealing
  # (or :voting when vote_delay_s is 0).
  defp start_round(theme, n, overrides) do
    {code, ids} = lobby_with_players(theme, n, overrides)
    :ok = Game.start_game(code)
    for pid <- ids, do: submit_all(code, pid)
    code
  end

  defp remaining_s(view), do: (view.round.deadline_ms - System.system_time(:millisecond)) / 1000

  # The submitter of the current round and the other (eligible) player ids.
  defp submitter_and_voters(code) do
    view = Game.get_state(code)
    submitter = submitter_of(view)
    {submitter, for(p <- view.players, p.id != submitter, do: p.id)}
  end

  describe "listening delay and voting countdown" do
    # These assert the real 5s all-voted countdown.
    setup do
      put_test_env(:all_voted_countdown_ms, nil)
      :ok
    end

    test "votes stay closed during the listening delay, then open with no countdown" do
      theme = guess_who_theme()
      code = start_round(theme, 3, %{vote_delay_s: 1})

      view = Game.get_state(code)
      assert view.round_state == :revealing
      assert is_integer(view.round.votes_open_ms)
      submitter = submitter_of(view)
      voter = Enum.find(view.players, &(&1.id != submitter)).id
      assert Game.cast_vote(code, voter, submitter) == {:error, :not_voting}

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      assert_receive {:game_state, %{round_state: :voting, round: round}}, 2500
      assert round.deadline_ms == nil
    end

    test "the song ending during the listening delay opens voting with the full countdown" do
      theme = guess_who_theme()
      code = start_round(theme, 3, %{vote_delay_s: 10, vote_timer_s: 30})
      assert Game.get_state(code).round_state == :revealing

      assert Game.song_ended(code) == :ok
      view = Game.get_state(code)
      assert view.round_state == :voting
      assert is_integer(view.round.deadline_ms)
      assert remaining_s(view) > 29 and remaining_s(view) <= 30
    end

    test "a majority starts the countdown and everyone voting cuts it to 5s" do
      theme = guess_who_theme()
      code = start_round(theme, 5, %{vote_delay_s: 0, vote_timer_s: 30})

      view = Game.get_state(code)
      assert view.round_state == :voting
      submitter = submitter_of(view)
      [a, b, c, d] = for p <- view.players, p.id != submitter, do: p.id

      # 2 of 4 eligible is not a majority: still no countdown.
      for v <- [a, b], do: :ok = Game.cast_vote(code, v, submitter)
      assert Game.get_state(code).round.deadline_ms == nil

      # 3 of 4 starts the full countdown.
      :ok = Game.cast_vote(code, c, submitter)
      assert remaining_s(Game.get_state(code)) > 25

      # The last vote drops it to the short final countdown.
      :ok = Game.cast_vote(code, d, submitter)
      view = Game.get_state(code)
      assert view.round_state == :voting
      assert remaining_s(view) > 4 and remaining_s(view) <= 5
    end

    test "the song ending starts the countdown even with no votes" do
      theme = guess_who_theme()
      code = start_round(theme, 3, %{vote_delay_s: 0, vote_timer_s: 30})

      assert Game.get_state(code).round.deadline_ms == nil
      :ok = Game.song_ended(code)
      assert remaining_s(Game.get_state(code)) > 25
    end

    test "everyone voting never lengthens an earlier, shorter countdown" do
      theme = guess_who_theme()
      code = start_round(theme, 5, %{vote_delay_s: 0, vote_timer_s: 2})
      {submitter, [a, b, c, d]} = submitter_and_voters(code)

      for v <- [a, b, c], do: :ok = Game.cast_vote(code, v, submitter)
      deadline = Game.get_state(code).round.deadline_ms
      assert is_integer(deadline)

      # The 5s all-voted countdown is longer than the ~2s left: keep the deadline.
      :ok = Game.cast_vote(code, d, submitter)
      assert Game.get_state(code).round.deadline_ms == deadline
    end

    test "the song ending during a running countdown leaves the deadline unchanged" do
      theme = guess_who_theme()
      code = start_round(theme, 5, %{vote_delay_s: 0, vote_timer_s: 30})
      {submitter, [a, b, c, _d]} = submitter_and_voters(code)

      for v <- [a, b, c], do: :ok = Game.cast_vote(code, v, submitter)
      deadline = Game.get_state(code).round.deadline_ms
      assert is_integer(deadline)

      assert Game.song_ended(code) == :ok
      view = Game.get_state(code)
      assert view.round_state == :voting
      assert view.round.deadline_ms == deadline
    end

    test "the song ending during :results is rejected" do
      # Hold :results long enough to act on it.
      put_test_env(:results_pause_ms, 5_000)
      theme = guess_who_theme()
      code = start_round(theme, 3, %{vote_delay_s: 0, vote_timer_s: 1})

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      # Starts the ~1s countdown, which then expires into :results.
      :ok = Game.song_ended(code)
      assert_receive {:game_state, %{round_state: :results}}, 2500
      assert Game.song_ended(code) == {:error, :not_playing}
      assert Game.get_state(code).round_state == :results
    end

    test "the voting safety timeout starts the countdown when nothing else does" do
      put_test_env(:voting_safety_ms, 200)
      theme = guess_who_theme()
      code = start_round(theme, 3, %{vote_delay_s: 0, vote_timer_s: 30})

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      # No votes and no song_ended: the safety timer alone starts the countdown.
      assert_receive {:game_state, %{round_state: :voting, round: %{deadline_ms: d}} = view}
                     when is_integer(d),
                     2000

      assert remaining_s(view) > 25
    end

    test "skipping during a running countdown moves on without a stray :results" do
      theme = guess_who_theme()
      code = start_round(theme, 5, %{vote_delay_s: 0, vote_timer_s: 1})
      {submitter, [a, b, c, _d]} = submitter_and_voters(code)
      index = Game.get_state(code).round.index

      for v <- [a, b, c], do: :ok = Game.cast_vote(code, v, submitter)
      assert is_integer(Game.get_state(code).round.deadline_ms)

      assert Game.skip_song(code) == :ok

      view = Game.get_state(code)
      assert view.round.index == index + 1
      assert view.round_state == :voting
      assert view.round.deadline_ms == nil
    end
  end

  describe "disconnection during voting" do
    # Asserts the real 5s all-voted countdown.
    setup do
      put_test_env(:all_voted_countdown_ms, nil)
      :ok
    end

    test "a disconnect can complete a majority and then everyone-voted" do
      theme = guess_who_theme()
      code = start_round(theme, 5, %{vote_delay_s: 0, vote_timer_s: 30})
      {submitter, [a, b, c, _d]} = submitter_and_voters(code)

      # 2 of 4 eligible: no countdown yet.
      for v <- [a, b], do: :ok = Game.cast_vote(code, v, submitter)
      assert Game.get_state(code).round.deadline_ms == nil

      # d drops: 2 of 3 connected eligible voters is a majority.
      :ok = Game.presence_diff(code, [submitter, a, b, c])
      view = Game.get_state(code)
      assert view.round_state == :voting
      assert remaining_s(view) > 25

      # c (the last non-voter) drops: everyone still connected has voted.
      :ok = Game.presence_diff(code, [submitter, a, b])
      view = Game.get_state(code)
      assert view.round_state == :voting
      assert remaining_s(view) > 4 and remaining_s(view) <= 5
    end
  end

  describe "revealed round exposes the correct answer" do
    test "guess_who: correct_choice is nil pre-reveal, the submitter at results" do
      theme = guess_who_theme()
      {code, view} = start_voting(theme)

      # Pre-reveal: never leaked.
      assert view.round.revealed == false
      assert view.round.correct_choice == nil
      assert view.round.correct_prompt == nil

      submitter = submitter_of(view)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      for p <- view.players, p.id != submitter, do: Game.cast_vote(code, p.id, submitter)

      assert_receive {:game_state, %{round_state: :results, round: round}}, 2500
      assert round.correct_choice == submitter
      # guess_who has no prompt to reveal.
      assert round.correct_prompt == nil
    end

    test "guess_question: correct_choice/prompt hidden pre-reveal, exposed at results" do
      theme = insert_theme([:guess_question])
      insert_questions(theme, :guess_question, 8)
      {code, ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      for pid <- ids, do: submit_all(code, pid)
      :ok = Game.song_ended(code)

      view = Game.get_state(code)
      assert view.round_state == :voting
      assert view.round.correct_choice == nil
      assert view.round.correct_prompt == nil

      submitter = submitter_of(view)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      # Voting any valid choice drives the round to results (need not be correct).
      choice = hd(view.round.choices).id
      for p <- view.players, p.id != submitter, do: Game.cast_vote(code, p.id, choice)

      assert_receive {:game_state, %{round_state: :results, round: round}}, 2500
      # The correct choice is a question id, and its prompt matches the matching
      # entry in the (already-exposed) choices list.
      assert is_binary(round.correct_choice)
      correct = Enum.find(round.choices, &(&1.id == round.correct_choice))
      assert round.correct_prompt == correct.prompt
    end
  end

  describe "player_view :me flags" do
    test "own_round? is true only for the current round's submitter during voting" do
      theme = guess_who_theme()
      {code, view} = start_voting(theme)

      submitter = submitter_of(view)
      assert Game.player_view(code, submitter).me.own_round? == true

      for p <- view.players, p.id != submitter do
        assert Game.player_view(code, p.id).me.own_round? == false
      end
    end

    test "missed_count reflects unsubmitted assignments once answering has ended" do
      theme = guess_who_theme()
      {code, [p1, p2, p3]} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      # Two players submit; p3 never does. The ~1s answer timer moves us into
      # playing with p3's question dropped.
      submit_all(code, p1)
      submit_all(code, p2)
      assert_receive {:game_state, %{phase: :playing}}, 3000

      assert Game.player_view(code, p3).me.missed_count == 1
      assert Game.player_view(code, p1).me.missed_count == 0
    end
  end

  describe "disconnection during answering" do
    test "a disconnected player's prior submissions are preserved" do
      theme = guess_who_theme()
      {code, [p1, p2, p3]} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)

      submit_all(code, p1)

      # p1 drops (Presence no longer lists them).
      :ok = Game.presence_diff(code, [p2, p3])

      view = Game.get_state(code)
      assert Enum.find(view.players, &(&1.id == p1)).connected? == false
      # Still counted as submitted, and still in the private player view.
      assert view.answering.progress[p1] == %{submitted: 1, total: 1}
      assert hd(Game.player_view(code, p1).me.assigned).submitted? == true
      # Game is still in answering, waiting on the others (not stalled/crashed).
      assert view.phase == :answering
    end

    test "answering advances early when the last non-submitter disconnects" do
      theme = guess_who_theme()
      # A long answer timer proves the advance is early, not a timer expiry.
      {code, [p1, p2, p3]} = lobby_with_players(theme, 3, %{answer_timer_s: 60})
      :ok = Game.start_game(code)

      # Two players submit everything; the third never submits.
      submit_all(code, p1)
      submit_all(code, p2)
      assert Game.get_state(code).phase == :answering

      # The lone remaining blocker disconnects -> answering completes early.
      :ok = Game.presence_diff(code, [p1, p2])

      view = Game.get_state(code)
      assert view.phase == :playing
      # p3's connection is reflected as dropped.
      assert Enum.find(view.players, &(&1.id == p3)).connected? == false
    end
  end

  describe "invalid events in the wrong state" do
    test "are rejected without crashing the game process" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id, @fast_overrides)
      {:ok, %{player_id: pid}} = Game.join(code, "A")

      pid_before = which_pid(code)

      assert Game.cast_vote(code, pid, "x") == {:error, :not_voting}
      assert Game.submit_song(code, pid, "q", song("s")) == {:error, :not_answering}
      assert Game.song_ended(code) == {:error, :not_playing}
      assert Game.skip_song(code) == {:error, :not_playing}
      assert Game.play_again(code) == {:error, :not_finished}
      assert Game.set_config(code, %{vote_timer_s: 5}) == :ok

      # Process survived every invalid event.
      assert Game.exists?(code)
      assert which_pid(code) == pid_before
      assert Process.alive?(pid_before)
    end
  end

  describe "play_again" do
    test "resets a finished game to the lobby, keeping the roster" do
      theme = guess_who_theme()
      {code, ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      for pid <- ids, do: submit_all(code, pid)
      final = play_to_finish(code)
      assert final.phase == :finished

      :ok = Game.play_again(code)

      view = Game.get_state(code)
      assert view.phase == :lobby
      # Roster preserved, scores reset.
      assert Enum.map(view.players, & &1.id) |> Enum.sort() == Enum.sort(ids)
      assert Enum.all?(Map.values(view.scores), &(&1 == 0))
    end
  end

  describe "multi-style theme with sub-rounds" do
    test "collapsing sub-rounds still plays through to finished" do
      theme = insert_theme([:guess_who, :guess_question])
      insert_questions(theme, :guess_who, 6)
      insert_questions(theme, :guess_question, 6)

      {code, ids} =
        lobby_with_players(theme, 3, %{subrounds_enabled?: false})

      :ok = Game.start_game(code)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      # One collapsed answering phase across both styles.
      view = Game.get_state(code)
      assert view.phase == :answering
      assert view.subround_total == 1

      for pid <- ids, do: submit_all(code, pid)
      final = play_to_finish(code)
      assert final.phase == :finished
    end

    test "enabled sub-rounds produce one sub-round per style" do
      theme = insert_theme([:guess_who, :guess_question])
      insert_questions(theme, :guess_who, 6)
      insert_questions(theme, :guess_question, 6)

      {code, _ids} = lobby_with_players(theme, 3, %{subrounds_enabled?: true})
      :ok = Game.start_game(code)

      view = Game.get_state(code)
      assert view.subround_total == 2
      assert view.subround_index == 0
    end

    test "the collapsed multi-style answer timer scales with the style count" do
      theme = insert_theme([:guess_who, :guess_question])
      insert_questions(theme, :guess_who, 6)
      insert_questions(theme, :guess_question, 6)

      # Collapsed: one sub-round spanning both styles, answer_timer_s = 5.
      {code, _ids} =
        lobby_with_players(theme, 3, %{subrounds_enabled?: false, answer_timer_s: 5})

      before_ms = System.system_time(:millisecond)
      :ok = Game.start_game(code)

      view = Game.get_state(code)
      assert view.subround_total == 1
      assert view.subround_styles == [:guess_who, :guess_question]

      # Two styles => 5s * 2 = ~10s window, not the flat ~5s a single style gets.
      span = view.answering.deadline_ms - before_ms
      assert span > 8_000
      assert span <= 10_500
    end
  end

  describe "host_state" do
    test "exposes the Spotify token only through the host-scoped query" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)
      :ok = Game.set_spotify(code, @premium)

      # Never in the shared view...
      refute Map.has_key?(Game.get_state(code), :spotify)
      # ...but present for the host.
      assert Game.host_state(code).spotify.access_token == "tok"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp which_pid(code) do
    case Registry.lookup(WhoseJam.Game.Registry, code) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
