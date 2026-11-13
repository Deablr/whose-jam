defmodule WhoseJamWeb.E2E.RoughNightTest do
  # The game when the room doesn't behave: a wrong room code, a search with
  # nothing in it and one with plenty, a changed pick, votes changed after
  # they're cast, someone who never votes before the clock runs out, a phone
  # that drops out and comes back, a friend who turns up late and joins the
  # audience, a tie for first, and Play again. In real browsers against the
  # real server (see `mix test.e2e`); only the music service is fake. Every
  # device is recorded into one combined video at @video.
  use PhoenixTest.Playwright.Case, async: false
  use WhoseJamWeb, :verified_routes

  alias WhoseJam.Game.Standings
  alias WhoseJamWeb.E2E.Stage

  @moduletag :e2e
  @moduletag timeout: to_timeout(minute: 10)

  @video "tmp/e2e/rough_night.mp4"
  @theme "Certified Bangers"
  @wait to_timeout(second: 40)
  @vote_timer_s 15

  # {key, name, device}. The second name is as long as a name may be.
  @players [
    {:ava, "Ava", :iphone_15},
    {:max, "Maximiliana-Rose", :iphone_se},
    {:ben, "Ben", :pixel_8},
    {:cleo, "Cleo", :galaxy_s24}
  ]

  # Turns up once the game has started, so watches and votes as audience.
  @latecomer {:dev, "Dev", :ipad_mini}

  # What each player picks, and how: {first search, second search, song}.
  # Ava searches for something that isn't there, then changes her pick.
  @picks %{
    ava: [{"zzz", nil}, {"neon", "Neon Overdrive"}, :change, {"lucy", "Paper Planes at Midnight"}],
    max: [{"e", "Rewind to Summer"}],
    ben: [{"slow", "Slow Burn Sunday"}],
    cleo: [{"concrete", "Concrete Garden"}]
  }

  setup do
    previous = Application.fetch_env!(:whose_jam, :results_pause_ms)
    Application.put_env(:whose_jam, :results_pause_ms, 7_000)
    on_exit(fn -> Application.put_env(:whose_jam, :results_pause_ms, previous) end)
  end

  test "a rough night: mistakes, dropouts, a latecomer and a tie", context do
    {late_key, late_name, late_device} = @latecomer

    roles =
      [{:host, "Host", :tv} | @players] ++ [{late_key, "#{late_name} (late)", late_device}]

    Stage.record(context, roles, @video, fn devices ->
      {code, join_url} = host_game(devices.host)

      wrong_code_then_join(devices.ava, code)
      join(devices.max, join_url, "Maximiliana-Rose")
      join(devices.ben, join_url, "Ben")
      join(devices.cleo, join_url, "Cleo")

      devices.host
      |> assert_has("#player-count", text: "4/")
      |> click_button("Start game")

      join_late(Map.fetch!(devices, late_key), join_url, late_name)
      pick_songs(devices)

      scores = play_rounds(devices)

      assert_tie_at_the_top(devices.host, scores)
      Stage.hold(to_timeout(second: 10))

      play_again(devices)
    end)
  end

  # --- setting up ------------------------------------------------------------

  defp host_game(host) do
    host
    |> visit(~p"/")
    |> assert_connected()
    |> click_button("Choose a theme")
    |> within("li:has(h3:text-is('#{@theme}'))", &click_button(&1, "Host this"))
    |> assert_has("p", text: "Room code")
    |> assert_connected()
    |> within("#music-prompt-modal", &click_button(&1, nil, "Connect", exact: true))
    |> refute_has("#music-prompt-modal")
    |> click_button("Settings")
    |> fill_in("Time to pick songs (s)", with: "120")
    |> fill_in("Prompts per player", with: "1")
    |> fill_in("Listen before voting opens (s)", with: "10")
    |> fill_in("Voting time (s)", with: Integer.to_string(@vote_timer_s))
    # Votes can be changed until the clock runs out: a tap is the vote.
    |> check("Allow changing a vote")
    # This host likes every screen choice the other way: quick reveals,
    # nobody named for missing a vote, every place on the score strip, and
    # the last round's totals shown as they land.
    |> check("Quick reveals: everything at once")
    |> uncheck("Name who didn't vote")
    |> check("Show every place on the score strip")
    |> uncheck("Hide totals during the final round")
    |> Stage.then_hold(to_timeout(second: 2))
    |> click_button("Close settings")
    |> assert_has(".jam-quick")

    "/host/" <> code = current_path(host)
    shown = text_of(host, "#join-url")
    {code, "#{URI.parse(WhoseJamWeb.Endpoint.url()).scheme}://#{shown}"}
  end

  # A mistyped code says so, and the right one gets in.
  defp wrong_code_then_join(session, code) do
    wrong = if code == "ZZZZ", do: "YYYY", else: "ZZZZ"

    session
    |> visit(~p"/")
    |> assert_connected()
    |> type("input[name=code]", wrong, delay: 90)
    |> click_button(nil, "Join", exact: true)
    |> assert_has("h1", text: "No game here", timeout: @wait)
    |> assert_connected()
    |> Stage.then_hold(to_timeout(second: 2))
    # The right code goes in right there.
    |> assert_has("#try-code", text: "Check the code on the TV.")
    |> fill_in("Room code", with: code)
    |> click_button("Try code")
    |> name_and_join("Ava")
  end

  defp join(session, join_url, name) do
    session
    |> visit(join_url)
    |> name_and_join(name)
  end

  defp name_and_join(session, name) do
    session
    |> assert_has("h1", text: "Pick a name", timeout: @wait)
    |> assert_connected()
    |> type("input[name=name]", name, delay: 60)
    |> click_button("Join game")
    |> assert_has("h1", text: "You're in")
  end

  # The game has started, so the latecomer joins the audience.
  defp join_late(session, join_url, name) do
    session
    |> visit(join_url)
    |> assert_has("h1", text: "Pick a name", timeout: @wait)
    |> assert_connected()
    # Told before the name goes in that this joins the audience.
    |> assert_has("#audience-join-note", text: "you'll join the audience")
    |> type("input[name=name]", name, delay: 60)
    |> click_button("Join the audience")
    |> assert_has("body", text: "Audience", timeout: @wait)
  end

  # --- picking ----------------------------------------------------------------

  # Ava goes first and changes her mind while the others are still choosing
  # (the last pick ends the picking); then the rest pick at once.
  defp pick_songs(devices) do
    pick(devices, {:ava, @picks.ava})
    in_parallel(Enum.reject(@picks, &(elem(&1, 0) == :ava)), &pick(devices, &1))
  end

  defp pick(devices, {key, steps}) do
    session = devices |> Map.fetch!(key) |> assert_has("input[name=q]", timeout: @wait)
    Enum.reduce(steps, session, &pick_step/2)
  end

  # A search that finds nothing says so.
  defp pick_step({query, nil}, session) do
    session
    |> type("input[name=q]", query, delay: 120)
    |> assert_has("#no-matches", text: "No songs found", timeout: @wait)
    |> Stage.then_hold(to_timeout(second: 2))
    |> fill_in("Search for a song", with: "")
  end

  # A locked-in pick can be changed while the others are still choosing.
  defp pick_step(:change, session) do
    session
    |> assert_has("button", text: "Change pick", timeout: @wait)
    |> Stage.then_hold(to_timeout(second: 2))
    |> click_button("Change pick")
    |> assert_has("input[name=q]", timeout: @wait)
  end

  defp pick_step({query, song}, session) do
    session
    |> fill_in("Search for a song", with: "")
    |> type("input[name=q]", query, delay: 120)
    |> assert_has("button", text: song, timeout: @wait)
    |> Stage.then_hold(to_timeout(second: 1))
    |> click_button(song)
  end

  # --- the rounds -------------------------------------------------------------

  # Four rounds, one song each. The script makes for a tie at the top: in the
  # first round one player never votes and the clock runs out; in every round
  # that player's song isn't, they fall for the wrong name, so two other
  # players each fool them once and finish level. Everyone else always calls
  # it, the latecomer included. Along the way a phone drops out and comes back,
  # and a vote is changed before the clock runs out.
  defp play_rounds(devices) do
    keys = Enum.map(@players, &elem(&1, 0))
    initial = Map.new(keys, &{&1, 0})

    Enum.reduce(1..length(@players), {initial, nil}, fn round, {scores, slacker} ->
      devices.host
      |> assert_has("p", text: "Round #{round} of #{length(@players)}", timeout: @wait)

      submitter = submitter_on_screen(devices.host)
      slacker = slacker || Enum.find(keys, &(&1 != submitter))

      if round == 2, do: drop_out_and_back(devices.cleo)

      votes = votes_for(round, submitter, slacker, keys)
      play_round(devices, round, submitter, votes)

      # The one who let the clock run out is counted on the reveal (not
      # named: this host turned that off), and with nobody fooled it isn't
      # "everyone" who saw through it. Every place shows on the strip.
      if round == 1 do
        devices.host
        |> assert_has("#said-none", text: "1 didn't vote")
        |> refute_has("#said-none", text: name_of(slacker))
        |> assert_has("#reveal-summary", text: "Nobody fell for it.")
        |> assert_has("#score-strip", text: "1st")
      end

      # The last round's totals land as every other round's do: this host
      # turned the final suspense off.
      if round == length(@players), do: refute_has(devices.host, "#strip-label")

      {tally(scores, submitter, votes), slacker}
    end)
    |> elem(0)
  end

  defp submitter_on_screen(host) do
    song = text_of(host, "h1")
    {key, _steps} = Enum.find(@picks, fn {_key, steps} -> last_song(steps) == song end)
    key
  end

  # Who names whom: everyone calls it, except that the slacker sits out the
  # first round and is fooled in every round after it that isn't theirs.
  defp votes_for(round, submitter, slacker, keys) do
    for voter <- keys, voter != submitter, not (round == 1 and voter == slacker) do
      if voter == slacker,
        do: {voter, Enum.find(keys, &(&1 not in [submitter, slacker]))},
        else: {voter, submitter}
    end
  end

  defp play_round(devices, round, submitter, votes) do
    picker = Map.fetch!(devices, submitter)

    # The picker's prediction: never the one the slacker names, so it never
    # comes true and the tie stands.
    blamed = votes |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 == submitter))
    guess = Enum.find(Map.keys(@picks), &(&1 != submitter and &1 not in blamed))

    picker
    |> assert_has("#phone-voting h1",
      text: "Whose jam is this?",
      timeout: @wait
    )
    |> click_button(nil, name_of(guess), exact: true)

    in_parallel(votes, fn {voter, choice} -> vote(devices, round, voter, choice) end)

    # The latecomer votes from the audience: they always call it.
    devices.dev
    |> assert_has("#phone-voting h1", text: "Whose jam is this?", timeout: @wait)
    |> click_button(nil, name_of(submitter), exact: true)

    devices.host
    |> assert_has("p", text: "It was", timeout: @wait + to_timeout(second: @vote_timer_s))
    |> assert_has("p.font-display", text: name_of(submitter))
  end

  # In the second round the first voter changes their mind before the clock
  # runs out: a tap is the vote, and another tap replaces it.
  defp vote(devices, round, voter, choice) do
    session =
      devices
      |> Map.fetch!(voter)
      |> assert_has("#phone-voting h1", text: "Whose jam is this?", timeout: @wait)

    if round == 2 and voter == :ava do
      wrong = Enum.find(Map.keys(@picks), &(&1 not in [voter, choice]))

      session
      |> click_button(nil, name_of(wrong), exact: true)
      |> assert_has("p", text: "Vote's in.")
      |> Stage.then_hold(to_timeout(second: 2))
      |> click_button(nil, name_of(choice), exact: true)
    else
      click_button(session, nil, name_of(choice), exact: true)
    end
  end

  # A phone that leaves the game by accident (back to the home page) is
  # offered the way straight back in, as the same player.
  defp drop_out_and_back(session) do
    session
    |> visit(~p"/")
    |> assert_connected()
    |> assert_has("#back-to-game", text: "Back to your game")
    |> Stage.then_hold(to_timeout(second: 3))
    |> click_link("Back to your game")
    |> assert_has("#me", text: "Cleo", timeout: @wait)
  end

  defp tally(scores, submitter, votes) do
    Enum.reduce(votes, scores, fn
      {voter, ^submitter}, acc -> Map.update!(acc, voter, &(&1 + 1))
      {_voter, _other}, acc -> Map.update!(acc, submitter, &(&1 + 1))
    end)
  end

  # --- the end ----------------------------------------------------------------

  # The script leaves two players level at the top: the TV names them both.
  defp assert_tie_at_the_top(host, scores) do
    board =
      @players
      |> Enum.map(fn {key, name, _device} -> %{id: key, name: name} end)
      |> Standings.rank(scores)

    winners = for row <- board, row.rank == 1, do: row.name
    assert length(winners) == 2

    host
    |> assert_has("p", text: "It's a tie", timeout: @wait)
    |> then(fn host -> Enum.reduce(winners, host, &assert_has(&2, "h1#winner", text: &1)) end)
  end

  # Play again keeps everyone in and goes back to the lobby; the latecomer
  # who watched from the audience takes a free seat and plays this time. The
  # next game deals new prompts.
  defp play_again(devices) do
    devices.host
    |> click_button("Play again")
    |> assert_has("#player-count", text: "5/", timeout: @wait)
    |> assert_has("#lobby-players li", text: "Maximiliana-Rose")
    |> assert_has("#lobby-players li", text: "Dev")

    devices.dev
    |> assert_has("h1", text: "You're in, Dev", timeout: @wait)
    |> assert_has("#promoted", text: "A seat opened up. You're playing this time.")

    devices.ava
    |> assert_has("h1", text: "You're in", timeout: @wait)

    Stage.hold(to_timeout(second: 4))

    devices.host
    |> click_button("Start game")
    |> assert_has("h1", text: "Heads down", timeout: @wait)

    devices.ava
    |> assert_has("input[name=q]", timeout: @wait)

    Stage.hold(to_timeout(second: 5))
  end

  # --- helpers ----------------------------------------------------------------

  defp last_song(steps), do: steps |> Enum.filter(&is_tuple/1) |> List.last() |> elem(1)

  defp name_of(key) do
    {_key, name, _device} = List.keyfind!(@players, key, 0)
    name
  end

  defp assert_connected(session), do: assert_has(session, "[data-phx-main].phx-connected")

  defp current_path(session) do
    evaluate(session, "location.pathname", &send(self(), {:path, &1}))
    assert_received {:path, path}
    path
  end

  defp text_of(session, selector) do
    evaluate(
      session,
      "document.querySelector(#{Jason.encode!(selector)})?.textContent.trim()",
      &send(self(), {:text, &1})
    )

    assert_received {:text, text} when is_binary(text)
    text
  end

  defp in_parallel(items, fun) do
    items
    |> Task.async_stream(&capture(fun, &1), timeout: :infinity)
    |> Enum.to_list()
    |> Enum.each(fn
      {:ok, :ok} -> :ok
      {:ok, {kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
    end)
  end

  defp capture(fun, item) do
    fun.(item)
    :ok
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end
end
