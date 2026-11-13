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
    # countdown (normally 3s) so the suite stays fast. Countdown tests that
    # assert the real 3s clear this again.
    put_test_env(:all_voted_countdown_ms, 20)
    # ...and skip the pause that follows the last song pick, so a play-through
    # can act on the first round as soon as everyone has submitted.
    put_test_env(:all_in_pause_ms, 0)

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

  # Drop any `{:game_state, _}` broadcasts already in the mailbox.
  defp flush_game_state do
    receive do
      {:game_state, _} -> flush_game_state()
    after
      0 -> :ok
    end
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

  # Create a game, join `n` players, connect Spotify Premium, apply fast timers.
  defp lobby_with_players(theme, n, extra_overrides \\ %{}) do
    {:ok, code} = Game.create_game(theme.id, Map.merge(@fast_overrides, extra_overrides))

    ids =
      for i <- 1..n do
        {:ok, %{player_id: id, role: :player}} = Game.join(code, "P#{i}")
        id
      end

    :ok = Game.set_music(code, :spotify, @premium)
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

            lock_forecast(code, view, submitter)
            play_to_finish(code)

          _ ->
            play_to_finish(code)
        end
    after
      5000 -> flunk("game did not reach :finished")
    end
  end

  # The submitter locks in too (their forecast: any other player will do), so
  # the round has everyone in and doesn't wait out the vote timer.
  defp lock_forecast(code, view, submitter) do
    if submitter not in view.round.voters do
      other = Enum.find(view.players, &(&1.id != submitter)).id
      Game.cast_vote(code, submitter, other)
    end
  end

  # Like play_to_finish/1, asserting along the way that each round shows the
  # prompt its submitter answered. Returns the indexes of the rounds checked.
  defp check_prompts_to_finish(code, prompts, checked) do
    receive do
      {:game_state, %{phase: :finished}} ->
        checked

      {:game_state, %{phase: :playing, round_state: state} = view}
      when state in [:revealing, :voting] ->
        submitter = submitter_of(view)
        assert view.round.prompt == Map.fetch!(prompts, submitter)

        if state == :revealing do
          Game.song_ended(code)
        else
          for p <- view.players, p.id != submitter, p.id not in view.round.voters do
            Game.cast_vote(code, p.id, submitter)
          end

          lock_forecast(code, view, submitter)
        end

        check_prompts_to_finish(code, prompts, MapSet.put(checked, view.round.index))

      {:game_state, _view} ->
        check_prompts_to_finish(code, prompts, checked)
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
      :ok = Game.set_music(code, :spotify, @premium)

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

    test "the host's presentation choices reach every screen's view" do
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 2)

      assert %{
               quick_reveals?: false,
               name_non_voters?: true,
               show_places?: false,
               final_suspense?: true
             } = Game.get_state(code).config

      for {key, value} <- [
            {"quick_reveals?", "true"},
            {"name_non_voters?", "false"},
            {"show_places?", "true"},
            {"final_suspense?", "false"}
          ],
          do: :ok = Game.set_config(code, %{key => value})

      assert %{
               quick_reveals?: true,
               name_non_voters?: false,
               show_places?: true,
               final_suspense?: false
             } = Game.get_state(code).config
    end

    test "requires a connected music service whose account is eligible" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id, @fast_overrides)
      for i <- 1..3, do: Game.join(code, "P#{i}")

      assert Game.start_game(code) == {:error, :not_authenticated}

      :ok = Game.set_music(code, :spotify, %{access_token: "t", premium?: false})
      assert Game.start_game(code) == {:error, :not_eligible}

      :ok = Game.set_music(code, :spotify, @premium)
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

      # Awards and recaps are for a finished game only.
      assert Game.get_state(code).awards == nil
      assert Game.player_view(code, p1).me.recap == nil

      final = play_to_finish(code)

      assert final.phase == :finished
      assert final.round == nil
      # Winner(s) are computed and players/audience are kept separate.
      assert is_list(final.winners.players)
      assert final.winners.audience == []
      # Everyone voted correctly every round, so guessers accrued points.
      assert Enum.any?(Map.values(final.scores), &(&1 > 0))
      # ...nobody was fooled, and all three called both songs that weren't theirs.
      assert final.awards.best_bluff == nil
      assert %{called: 2, player_ids: sharpest} = final.awards.sharpest
      assert Enum.sort(sharpest) == Enum.sort([p1, p2, p3])
      # Each player's own view says how their own game went.
      assert Game.player_view(code, p1).me.recap == %{called: 2, fooled: 0, blamed: 0}
      # The night's songs, in the order played, each with whose it was and
      # its cover (none for these test songs).
      assert length(final.playlist) == 3
      assert Enum.sort(Enum.map(final.playlist, & &1.player_id)) == Enum.sort([p1, p2, p3])

      for song <- final.playlist,
          do: assert(%{artist: "Artist", album_art_url: nil} = song)
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

    test "song name and artist are trimmed, capped at 200 codepoints, and non-strings become empty" do
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

      # Stacked combining marks form one grapheme; the cap still bounds bytes.
      zalgo = "a" <> String.duplicate("\u0301", 100_000)
      song = stored.(zalgo, zalgo)
      assert byte_size(song.name) <= 800
      assert byte_size(song.artist) <= 800
      assert String.starts_with?(song.name, "a\u0301")
    end
  end

  describe "everyone has picked" do
    test "the first song waits a moment, so the last pick is seen landing" do
      put_test_env(:all_in_pause_ms, 150)
      theme = guess_who_theme()
      {code, ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      for pid <- ids, do: submit_all(code, pid)

      # Still picking, with everyone shown as done...
      view = Game.get_state(code)
      assert view.phase == :answering
      assert Enum.all?(view.answering.progress, fn {_id, p} -> p.submitted == p.total end)

      # ...then the first round starts by itself.
      assert_receive {:game_state, %{phase: :playing, round: %{index: 0}}}, 2000
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

    test "the submitter's choice is a forecast of the room's wrong answer, never a vote" do
      put_test_env(:all_voted_countdown_ms, 20)
      theme = guess_who_theme()
      {code, view} = start_voting(theme)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      submitter = submitter_of(view)
      [a, b] = for p <- view.players, p.id != submitter, do: p.id

      # The submitter says the room will blame b. It is theirs to see...
      assert Game.cast_vote(code, submitter, b) == :ok
      assert Game.player_view(code, submitter).me.vote == b
      # ...and can't be changed, like any vote.
      assert Game.cast_vote(code, submitter, a) == {:error, :already_voted}

      # a falls for it (blames b); b calls it.
      assert Game.cast_vote(code, a, b) == :ok
      assert Game.cast_vote(code, b, submitter) == :ok

      assert_receive {:game_state, %{round_state: :results, round: round}}, 1000

      # The forecast came true, and is no vote: only a and b voted.
      assert round.forecast == %{choice: b, right?: true}
      assert Enum.sort(Enum.map(round.votes, & &1.voter_id)) == Enum.sort([a, b])
      # One player fooled, plus one for seeing it coming; b called it.
      assert round.deltas == %{submitter => 2, b => 1}
    end

    test "a forecast that doesn't come true earns nothing" do
      put_test_env(:all_voted_countdown_ms, 20)
      theme = guess_who_theme()
      {code, view} = start_voting(theme)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      submitter = submitter_of(view)
      [a, b] = for p <- view.players, p.id != submitter, do: p.id

      # The submitter says the room will blame a; nobody does.
      assert Game.cast_vote(code, submitter, a) == :ok
      assert Game.cast_vote(code, a, b) == :ok
      assert Game.cast_vote(code, b, submitter) == :ok

      assert_receive {:game_state, %{round_state: :results, round: round}}, 1000
      assert round.forecast == %{choice: a, right?: false}
      assert round.deltas == %{submitter => 1, b => 1}
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

    test "a voting round says who has locked in, the submitter among them, and keeps what they chose secret" do
      theme = guess_who_theme()
      {code, view} = start_voting(theme)

      submitter = submitter_of(view)
      [a, b] = for p <- view.players, p.id != submitter, do: p.id

      # Three players: the round waits for all three, the submitter included
      # (who is in says nothing about whose song it is).
      assert view.round.eligible_voters == 3
      assert view.round.voters == []
      assert view.round.votes == nil
      assert view.round.forecast == nil

      assert Game.cast_vote(code, a, b) == :ok

      view = Game.get_state(code)
      assert view.round.votes_received == 1
      assert view.round.voters == [a]
      # Who chose what stays hidden until the reveal...
      assert view.round.votes == nil
      # ...except from the voter, whose own view carries their own choice.
      assert Game.player_view(code, a).me.vote == b
      assert Game.player_view(code, b).me.vote == nil
      assert Game.player_view(code, submitter).me.vote == nil

      # The submitter's forecast puts them in the list like anyone else.
      assert Game.cast_vote(code, submitter, a) == :ok

      view = Game.get_state(code)
      assert view.round.votes_received == 2
      assert Enum.sort(view.round.voters) == Enum.sort([a, submitter])
      assert view.round.eligible_voters == 3
      assert view.round.votes == nil
      assert view.round.forecast == nil
    end

    test "the reveal carries who voted for what" do
      # Hold :results long enough to read it.
      put_test_env(:results_pause_ms, 5_000)
      theme = guess_who_theme()
      {code, view} = start_voting(theme)

      submitter = submitter_of(view)
      [a, b] = for p <- view.players, p.id != submitter, do: p.id

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      assert Game.cast_vote(code, a, submitter) == :ok
      assert Game.cast_vote(code, b, a) == :ok

      assert_receive {:game_state, %{round_state: :results, round: round}}, 2500

      assert Enum.sort_by(round.votes, & &1.voter_id) ==
               Enum.sort_by(
                 [
                   %{voter_id: a, voter_role: :player, choice: submitter},
                   %{voter_id: b, voter_role: :player, choice: a}
                 ],
                 & &1.voter_id
               )

      # The phone can still say what its player picked.
      assert Game.player_view(code, b).me.vote == a
      # A screen can count down to the next song.
      assert round.next_ms > System.system_time(:millisecond)
    end

    test "a round says which pick for its prompt it is" do
      theme = guess_who_theme()
      {code, view} = start_voting(theme)

      # Every song in this game has a prompt; a prompt only one player got
      # says nothing, one that several got says which of their picks this is.
      rounds = for index <- 0..(view.round.total - 1), do: round_at(code, index)

      for {prompt, same} <- Enum.group_by(rounds, & &1.prompt) do
        takes = Enum.map(same, & &1.prompt_take)

        if length(same) == 1 do
          assert takes == [nil], "#{prompt} has one song"
        else
          assert Enum.map(takes, & &1.nth) == Enum.to_list(1..length(same))
          assert Enum.all?(takes, &(&1.of == length(same)))
        end
      end

      # Back to back means the round before had the same prompt.
      for {round, index} <- Enum.with_index(rounds), take = round.prompt_take do
        before = if index > 0, do: Enum.at(rounds, index - 1).prompt
        assert take.back_to_back? == (before == round.prompt)
      end
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

  # The round view at `index`, skipping songs to get there.
  defp round_at(code, index) do
    view = Game.get_state(code)

    if view.round.index < index do
      :ok = Game.skip_song(code)
      round_at(code, index)
    else
      view.round
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
    # These assert the real 3s all-voted countdown.
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

    test "a majority starts the countdown and everyone voting cuts it to 3s" do
      theme = guess_who_theme()
      code = start_round(theme, 5, %{vote_delay_s: 0, vote_timer_s: 30})

      view = Game.get_state(code)
      assert view.round_state == :voting
      submitter = submitter_of(view)
      [a, b, c, d] = for p <- view.players, p.id != submitter, do: p.id

      # 2 of 5 (the submitter is waited for too) is not a majority: still no
      # countdown.
      for v <- [a, b], do: :ok = Game.cast_vote(code, v, submitter)
      assert Game.get_state(code).round.deadline_ms == nil

      # 3 of 5 starts the full countdown.
      :ok = Game.cast_vote(code, c, submitter)
      assert remaining_s(Game.get_state(code)) > 25

      # Every voter in, but not the submitter's forecast: still the full one.
      :ok = Game.cast_vote(code, d, submitter)
      assert remaining_s(Game.get_state(code)) > 25

      # The last one in drops it to the short final countdown.
      :ok = Game.cast_vote(code, submitter, a)
      view = Game.get_state(code)
      assert view.round_state == :voting
      assert remaining_s(view) > 2 and remaining_s(view) <= 3
    end

    test "with vote changing on, everyone voting leaves 5s of final changes" do
      theme = guess_who_theme()

      code =
        start_round(theme, 3, %{vote_delay_s: 0, vote_timer_s: 30, allow_vote_change?: true})

      {submitter, [a, b]} = submitter_and_voters(code)

      :ok = Game.cast_vote(code, a, submitter)
      :ok = Game.cast_vote(code, b, submitter)
      assert remaining_s(Game.get_state(code)) > 25

      :ok = Game.cast_vote(code, submitter, a)
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

      # The 3s all-voted countdown is longer than the ~2s left: keep the deadline.
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

    test "skipping during a running countdown advances to the next round with no deadline" do
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
    # Asserts the real 3s all-voted countdown.
    setup do
      put_test_env(:all_voted_countdown_ms, nil)
      :ok
    end

    test "a disconnect can complete a majority and then everyone-voted" do
      theme = guess_who_theme()
      code = start_round(theme, 5, %{vote_delay_s: 0, vote_timer_s: 30})
      {submitter, [a, b, c, _d]} = submitter_and_voters(code)

      # 2 of 5 eligible (the submitter is one): no countdown yet.
      for v <- [a, b], do: :ok = Game.cast_vote(code, v, submitter)
      assert Game.get_state(code).round.deadline_ms == nil

      # d drops: 2 of 4 connected is still no majority.
      :ok = Game.presence_diff(code, [submitter, a, b, c])
      assert Game.get_state(code).round.deadline_ms == nil

      # c drops: 2 of 3 connected is a majority.
      :ok = Game.presence_diff(code, [submitter, a, b])
      view = Game.get_state(code)
      assert view.round_state == :voting
      assert remaining_s(view) > 25

      # The submitter (the last one not in) drops: everyone still connected
      # has locked in.
      :ok = Game.presence_diff(code, [a, b])
      view = Game.get_state(code)
      assert view.round_state == :voting
      assert remaining_s(view) > 2 and remaining_s(view) <= 3
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

  describe "the round's prompt" do
    test "every guess_who round shows the prompt its own song was picked for" do
      theme = guess_who_theme()
      # Four players with one question each: binning gives two prompts with
      # two submitters each, so a round showing another round's prompt shows.
      {code, ids} = lobby_with_players(theme, 4)
      :ok = Game.start_game(code)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)

      # Each player's single prompt, keyed by the player (= their song's name).
      prompts = Map.new(ids, fn pid -> {pid, hd(submit_all(code, pid)).prompt} end)
      assert prompts |> Map.values() |> Enum.uniq() |> length() == 2

      # While each song plays and while its votes are open.
      assert check_prompts_to_finish(code, prompts, MapSet.new()) == MapSet.new(0..3)
    end

    test "guess_question rounds never show it as context: the prompt is the answer" do
      theme = insert_theme([:guess_question])
      insert_questions(theme, :guess_question, 8)
      {code, ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      for pid <- ids, do: submit_all(code, pid)
      :ok = Game.song_ended(code)

      view = Game.get_state(code)
      assert view.round_state == :voting
      assert view.round.prompt == nil

      submitter = submitter_of(view)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      choice = hd(view.round.choices).id
      for p <- view.players, p.id != submitter, do: Game.cast_vote(code, p.id, choice)

      # Revealed as the answer instead.
      assert_receive {:game_state, %{round_state: :results, round: round}}, 2500
      assert round.prompt == nil
      assert is_binary(round.correct_prompt)
    end
  end

  describe "the end of a game" do
    # A stand-in for a host screen's LiveView process.
    defp host_screen(id) do
      start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: id))
    end

    # Hear the room's broadcasts and see the game's process stop.
    defp watch(code) do
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      Process.monitor(which_pid(code))
    end

    test "end_game from the final scoreboard tells every screen and stops the game" do
      theme = guess_who_theme()
      {code, ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      ref = watch(code)
      for pid <- ids, do: submit_all(code, pid)
      assert play_to_finish(code).phase == :finished

      assert Game.end_game(code) == :ok

      assert_receive {:game_ended, :host_ended}
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
      assert Game.get_state(code) == nil
      assert Game.end_game(code) == {:error, :not_found}
    end

    test "closing the last host screen ends the game once the grace runs out" do
      put_test_env(:host_grace_ms, 50)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:host))
      ref = watch(code)

      stop_supervised!(:host)

      assert_receive {:game_ended, :host_left}, 1000
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1000
    end

    test "a host screen that comes back within the grace keeps the game going" do
      put_test_env(:host_grace_ms, 100)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:before_refresh))
      watch(code)

      stop_supervised!(:before_refresh)
      :ok = Game.attach_host(code, host_screen(:after_refresh))

      refute_receive {:game_ended, _}, 300
      assert Game.get_state(code).phase == :lobby
    end

    test "the game lasts while any host screen is open" do
      put_test_env(:host_grace_ms, 50)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:tv))
      :ok = Game.attach_host(code, host_screen(:laptop))
      watch(code)

      stop_supervised!(:tv)
      refute_receive {:game_ended, _}, 200

      stop_supervised!(:laptop)
      assert_receive {:game_ended, :host_left}, 1000
    end

    # What a host screen's Connect link does: the OAuth controller tells the
    # game the host is signing in, then the screen goes once the provider's
    # page loads (a plain link keeps its page connected until then).
    defp leave_to_sign_in(code, screen) do
      result = Game.host_signing_in(code)
      stop_supervised!(screen)
      result
    end

    # The other order, for a host screen whose connection dropped just before
    # the click: the game sees the departure first, then the notice.
    defp drop_then_sign_in(code, screen) do
      stop_supervised!(screen)
      _ = :sys.get_state(which_pid(code))
      Game.host_signing_in(code)
    end

    test "a host screen that left to sign in to a music service gets the longer grace" do
      put_test_env(:host_grace_ms, 100)
      put_test_env(:sign_in_grace_ms, 600)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:host))
      watch(code)

      assert {:ok, _sign_in} = leave_to_sign_in(code, :host)

      # Well past the usual grace...
      refute_receive {:game_ended, _}, 300
      # ...but a sign-in that never comes back still ends the game.
      assert_receive {:game_ended, :host_left}, 1000
    end

    test "a host screen that dropped just before its sign-in notice gets the longer grace too" do
      put_test_env(:host_grace_ms, 100)
      put_test_env(:sign_in_grace_ms, 600)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:host))
      watch(code)

      assert {:ok, _sign_in} = drop_then_sign_in(code, :host)

      refute_receive {:game_ended, _}, 300
      assert_receive {:game_ended, :host_left}, 1000
    end

    test "a sign-in notice once the host screens are long gone is ignored" do
      put_test_env(:host_grace_ms, 100)
      put_test_env(:sign_in_grace_ms, 5_000)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:host))
      watch(code)

      assert {:ok, sign_in} = leave_to_sign_in(code, :host)
      # Past the usual grace, the game waits on that sign-in alone. Anyone with
      # the room code can still ask, but it can't be a host leaving now.
      refute_receive {:game_ended, _}, 250
      assert Game.host_signing_in(code) == {:error, :no_host_screen}

      # So once the host's sign-in is back, nothing else holds the game.
      :ok = Game.host_back_from_sign_in(code, sign_in)
      assert_receive {:game_ended, :host_left}, 1000
    end

    test "another host screen opening during a sign-in leaves the sign-in its grace" do
      put_test_env(:host_grace_ms, 100)
      put_test_env(:sign_in_grace_ms, 5_000)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:laptop))
      :ok = Game.attach_host(code, host_screen(:tv))
      watch(code)

      # The laptop leaves to sign in; meanwhile the TV refreshes, then closes.
      assert {:ok, _sign_in} = leave_to_sign_in(code, :laptop)
      stop_supervised!(:tv)
      :ok = Game.attach_host(code, host_screen(:tv_refreshed))
      stop_supervised!(:tv_refreshed)

      refute_receive {:game_ended, _}, 300
    end

    test "one sign-in coming back leaves another still under way its grace" do
      put_test_env(:host_grace_ms, 100)
      put_test_env(:sign_in_grace_ms, 5_000)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:laptop))
      :ok = Game.attach_host(code, host_screen(:tv))
      watch(code)

      # Both host screens leave to sign in; the laptop's comes back first but
      # its screen never reopens.
      assert {:ok, laptop} = leave_to_sign_in(code, :laptop)
      assert {:ok, tv} = leave_to_sign_in(code, :tv)
      :ok = Game.host_back_from_sign_in(code, laptop)
      refute_receive {:game_ended, _}, 300

      # Once the TV's is back too, the usual grace applies.
      :ok = Game.host_back_from_sign_in(code, tv)
      assert_receive {:game_ended, :host_left}, 1000
    end

    test "only a sign-in the game let in can end it, and only once" do
      put_test_env(:host_grace_ms, 100)
      put_test_env(:sign_in_grace_ms, 5_000)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:laptop))
      :ok = Game.attach_host(code, host_screen(:tv))
      watch(code)

      assert {:ok, laptop} = leave_to_sign_in(code, :laptop)
      assert {:ok, tv} = leave_to_sign_in(code, :tv)
      :ok = Game.host_back_from_sign_in(code, laptop)

      # A replayed callback, or one for a sign-in the game never let in (a
      # refused notice gives none), leaves the TV's sign-in under way.
      assert Game.host_back_from_sign_in(code, laptop) == {:error, :unknown_sign_in}
      assert Game.host_back_from_sign_in(code, "forged") == {:error, :unknown_sign_in}
      refute_receive {:game_ended, _}, 300

      :ok = Game.host_back_from_sign_in(code, tv)
      assert_receive {:game_ended, :host_left}, 1000
    end

    test "at most four sign-ins are under way at once" do
      put_test_env(:sign_in_grace_ms, 5_000)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:host))

      sign_ins = for _ <- 1..4, do: elem(Game.host_signing_in(code), 1)
      assert sign_ins |> Enum.uniq() |> length() == 4
      assert Game.host_signing_in(code) == {:error, :too_many_sign_ins}

      # One coming back makes room again; nothing under way is pushed out.
      :ok = Game.host_back_from_sign_in(code, hd(sign_ins))
      assert {:ok, _sign_in} = Game.host_signing_in(code)
    end

    test "a sign-in whose window has closed frees its place" do
      put_test_env(:sign_in_grace_ms, 50)
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)
      :ok = Game.attach_host(code, host_screen(:host))
      watch(code)

      for _ <- 1..4, do: assert({:ok, _sign_in} = Game.host_signing_in(code))
      refute_receive {:game_ended, _}, 100

      assert {:ok, _sign_in} = Game.host_signing_in(code)
    end

    test "a sign-in that never came back stops counting once its window closes" do
      put_test_env(:host_grace_ms, 100)
      put_test_env(:sign_in_grace_ms, 50)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:host))
      watch(code)

      # Started (say, from another tab) and abandoned; its window closes.
      assert {:ok, _abandoned} = Game.host_signing_in(code)
      refute_receive {:game_ended, _}, 150

      # A later sign-in comes back, but its host screen never does.
      put_test_env(:sign_in_grace_ms, 5_000)
      assert {:ok, sign_in} = leave_to_sign_in(code, :host)
      :ok = Game.host_back_from_sign_in(code, sign_in)

      assert_receive {:game_ended, :host_left}, 1000
    end

    test "once the sign-in is over, the usual grace applies again" do
      put_test_env(:host_grace_ms, 100)
      put_test_env(:sign_in_grace_ms, 5_000)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.attach_host(code, host_screen(:host))
      watch(code)

      assert {:ok, sign_in} = leave_to_sign_in(code, :host)
      # Long enough for the countdown to defer to the sign-in's window.
      refute_receive {:game_ended, _}, 250

      # The sign-in comes back, but its host screen never does.
      :ok = Game.host_back_from_sign_in(code, sign_in)
      assert_receive {:game_ended, :host_left}, 1000
    end

    test "a game no host screen has opened is not ended for want of one" do
      put_test_env(:host_grace_ms, 50)
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      watch(code)

      # Nor can a sign-in notice come from a host screen that never opened.
      assert Game.host_signing_in(code) == {:error, :no_host_screen}

      refute_receive {:game_ended, _}, 200
      assert Game.get_state(code).phase == :lobby
    end

    test "only a pid can attach as a host screen" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)

      assert Game.attach_host(code, "not a pid") == {:error, :invalid}
      assert Game.attach_host("NOPE", self()) == {:error, :not_found}
    end

    test "an abandoned lobby closes and tells every screen" do
      put_test_env(:abandoned_ttl_ms, 50)
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)
      ref = watch(code)

      assert_receive {:game_ended, :idle}, 1000
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1000
    end

    test "a finished game left alone closes and tells every screen" do
      put_test_env(:finished_shutdown_ms, 50)
      theme = guess_who_theme()
      {code, ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      ref = watch(code)
      for pid <- ids, do: submit_all(code, pid)
      assert play_to_finish(code).phase == :finished

      assert_receive {:game_ended, :idle}, 1000
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1000
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
      assert Game.attach_host(code, :not_a_pid) == {:error, :invalid}
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

    test "seats whoever watched from the audience, while seats are free" do
      theme = guess_who_theme()
      {code, ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)

      # Two arrive after the start: audience for this game.
      {:ok, %{player_id: late1, role: :audience}} = Game.join(code, "Late 1")
      {:ok, %{player_id: late2, role: :audience}} = Game.join(code, "Late 2")

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      for pid <- ids, do: submit_all(code, pid)
      assert play_to_finish(code).phase == :finished

      :ok = Game.play_again(code)

      view = Game.get_state(code)
      assert Enum.map(view.players, & &1.id) == ids ++ [late1, late2]
      assert view.audience == []
      assert Game.player_view(code, late1).me.role == :player
    end

    test "keeps the audience whom the free seats can't hold, in the order they joined" do
      theme = guess_who_theme()
      {code, ids} = lobby_with_players(theme, Game.max_players() - 1)
      :ok = Game.start_game(code)

      {:ok, %{player_id: first, role: :audience}} = Game.join(code, "First late")
      {:ok, %{player_id: second, role: :audience}} = Game.join(code, "Second late")

      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      for pid <- ids, do: submit_all(code, pid)
      assert play_to_finish(code).phase == :finished

      :ok = Game.play_again(code)

      view = Game.get_state(code)
      assert length(view.players) == Game.max_players()
      assert List.last(view.players).id == first
      assert Enum.map(view.audience, & &1.id) == [second]
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

  describe "music providers" do
    alias WhoseJam.Music
    alias WhoseJam.MusicFixtures

    # The same game runs unchanged on every provider: the runtime only ever
    # sees the provider-neutral song shape.
    for id <- WhoseJam.MusicFixtures.sample_ids() do
      @id id

      test "#{id}: connect, start, submit its own song, and see it back" do
        sample = MusicFixtures.sample(@id)
        {:ok, provider} = Music.fetch_provider(@id)

        theme = guess_who_theme()
        {:ok, code} = Game.create_game(theme.id, @fast_overrides)
        ids = for i <- 1..3, do: elem(Game.join(code, "P#{i}"), 1).player_id

        assert Game.start_game(code) == {:error, :not_authenticated}
        :ok = Game.set_music(code, @id, sample.auth)

        assert Game.get_state(code).music ==
                 %{
                   id: @id,
                   name: provider.name(),
                   video?: provider.video?(),
                   eligible?: true,
                   search_debounce_ms: provider.search_debounce_ms()
                 }

        :ok = Game.start_game(code)
        [p1 | _] = ids
        [q] = Game.player_view(code, p1).me.assigned

        assert Game.submit_song(code, p1, q.question_id, sample.song) == :ok
        assert hd(Game.player_view(code, p1).me.assigned).song == sample.song
      end

      test "#{id}: an ineligible account can't start the game" do
        sample = MusicFixtures.sample(@id)

        if sample.ineligible_auth do
          theme = guess_who_theme()
          {:ok, code} = Game.create_game(theme.id, @fast_overrides)
          for i <- 1..3, do: Game.join(code, "P#{i}")

          :ok = Game.set_music(code, @id, sample.ineligible_auth)
          assert Game.get_state(code).music.eligible? == false
          assert Game.start_game(code) == {:error, :not_eligible}
        end
      end
    end

    test "a song from another provider is rejected" do
      theme = guess_who_theme()
      {code, [p1 | _]} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)
      [q] = Game.player_view(code, p1).me.assigned

      for other <- [:mock] do
        foreign = MusicFixtures.sample(other).song

        assert Game.submit_song(code, p1, q.question_id, foreign) == {:error, :invalid_song}
      end
    end

    test "a degraded account (YouTube without Premium) is warned about but still starts" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id, @fast_overrides)
      for i <- 1..3, do: Game.join(code, "P#{i}")

      :ok = Game.set_music(code, :youtube, %{signed_in?: true, premium?: nil})

      {:ok, answered} =
        Music.answer_account_question(:youtube, Game.host_state(code).music_auth, false)

      :ok = Game.set_music(code, :youtube, answered)

      assert Game.get_state(code).music.eligible?
      assert Music.warning(:youtube, Game.host_state(code).music_auth) =~ "ads"
      assert Game.start_game(code) == :ok
    end

    test "an unknown or disabled provider can't be connected" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)

      assert Game.set_music(code, :nope, %{}) == {:error, :unknown_provider}
      assert Game.get_state(code).music == nil
    end

    test "the service can be switched in the lobby but not mid-game" do
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)

      :ok = Game.set_music(code, :mock, %{})
      assert Game.get_state(code).music.id == :mock
      :ok = Game.set_music(code, :spotify, @premium)

      :ok = Game.start_game(code)
      assert Game.set_music(code, :mock, %{}) == {:error, :not_lobby}
      # A same-provider update (token refresh) is still fine mid-game.
      assert Game.set_music(code, :spotify, %{@premium | access_token: "fresh"}) == :ok
      assert Game.host_state(code).music_auth.access_token == "fresh"
    end

    test "connecting broadcasts the new service, never its auth, to every client" do
      theme = guess_who_theme()
      {code, [p1 | _]} = lobby_with_players(theme, 3)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> code)
      flush_game_state()

      :ok = Game.set_music(code, :mock, %{secret: "s3cr3t"})

      assert_receive {:game_state, %{music: %{id: :mock}} = view}
      refute Map.has_key?(view, :music_auth)
      refute inspect(view) =~ "s3cr3t"
      refute Map.has_key?(Game.player_view(code, p1), :music_auth)
      assert Game.host_state(code).music_auth == %{secret: "s3cr3t"}
    end

    test "a fresh game has no music auth, and a non-map auth is rejected" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)

      assert Game.host_state(code).music_auth == nil
      assert {:error, _} = Game.set_music(code, :mock, nil)
      assert Game.get_state(code).music == nil
    end

    test "provider ids may be strings (as events and URLs carry them)" do
      theme = guess_who_theme()
      {code, _ids} = lobby_with_players(theme, 3)
      :ok = Game.start_game(code)

      # Same-provider refresh mid-game is allowed; a different one is not.
      assert Game.set_music(code, "spotify", %{@premium | access_token: "fresh"}) == :ok
      assert Game.set_music(code, "mock", %{}) == {:error, :not_lobby}
      assert Game.get_state(code).music.id == :spotify
    end

    test "players search the room's service" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)

      assert Game.search_songs(code, "neon") == {:error, :no_music}
      assert Game.search_songs("NOPE", "neon") == {:error, :not_found}

      :ok = Game.set_music(code, :mock, %{})
      assert {:ok, [%{name: "Neon Overdrive"}]} = Game.search_songs(code, "neon")
    end
  end

  describe "host_state" do
    test "exposes the music auth (and its token) only through the host-scoped query" do
      theme = guess_who_theme()
      {:ok, code} = Game.create_game(theme.id)
      :ok = Game.set_music(code, :spotify, @premium)

      # The shared view says which service, whether it can play and how to
      # search it — no auth...
      assert Game.get_state(code).music ==
               %{
                 id: :spotify,
                 name: "Spotify",
                 video?: false,
                 eligible?: true,
                 search_debounce_ms: 300
               }

      refute Map.has_key?(Game.get_state(code), :music_auth)
      # ...but the host gets the auth.
      assert Game.host_state(code).music_auth.access_token == "tok"
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
