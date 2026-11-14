defmodule WhoseJamWeb.E2E.FullGameTest do
  # One whole party, in real browsers: a host on the TV and eight players on
  # phones, tablets and laptops play a full game against the real server and a
  # real Postgres (see `mix test.e2e`). Only the music service is fake (the
  # Mock provider). Every device is recorded and the run leaves one combined
  # video at @video.
  use PhoenixTest.Playwright.Case, async: false
  use WhoseJamWeb, :verified_routes

  alias WhoseJam.Game.Standings
  alias WhoseJamWeb.E2E.Stage

  @moduletag :e2e
  @moduletag timeout: to_timeout(minute: 10)

  @video "tmp/e2e/full_game.mp4"
  @theme "Certified Bangers"
  @wait to_timeout(second: 30)

  # {key, name, device, search typed, song picked}. Each player picks a
  # different Mock track, so a song identifies its submitter.
  # Six of the songs are real (NoCopyrightSounds tracks the Mock provider
  # plays for real when `mix test.e2e` has copied them in), with long and
  # non-Latin titles; two are made up. Dev's phone asks for less motion.
  @players [
    {:ava, "Ava", :iphone_15, "anesthesia", "Anesthesia"},
    {:ben, "Ben", :pixel_8, "flirt", "FLIRT (if i don’t mean it)"},
    {:cleo, "Cleo", :iphone_se, "happier", "Happier Now"},
    {:dev, "Dev", {:galaxy_s24, reduced_motion?: true}, "concrete", "Concrete Garden"},
    {:eli, "Eli", :ipad_mini, "daydream", "デイドリーム (Daydream)"},
    {:fern, "Fern", :galaxy_tab_s9, "severed", "Severed Rose"},
    {:gus, "Gus", :macbook_air, "verse", "Re:バース (Re:Verse)"},
    {:hana, "Hana", :windows_laptop, "golden", "Golden Hour Hangover"}
  ]

  # One question each, so one round per player.
  @rounds length(@players)

  # Notes how the phone's result card looks the instant it is first on the
  # page (a MutationObserver runs before the next paint).
  @watch_outcome """
  (() => {
    const seen = () => {
      const card = document.querySelector("#my-outcome");
      if (card) window.firstOutcomeOpacity = getComputedStyle(card).opacity;
      return card !== null;
    };
    if (!seen()) {
      const watch = new MutationObserver(() => { if (seen()) watch.disconnect(); });
      watch.observe(document.body, {childList: true, subtree: true});
    }
  })()
  """

  setup do
    # config/test.exs shortens the reveal to a blink. Hold it long enough to
    # read in the video and for the per-round reveal assertions to see it
    # (a real game holds it for ten seconds).
    previous = Application.fetch_env!(:whose_jam, :results_pause_ms)
    Application.put_env(:whose_jam, :results_pause_ms, 8_000)
    on_exit(fn -> Application.put_env(:whose_jam, :results_pause_ms, previous) end)
  end

  test "a host and eight players play a whole game", context do
    roles = [
      {:host, "Host", :tv}
      | Enum.map(@players, fn {key, name, device, _, _} -> {key, name, device} end)
    ]

    Stage.record(context, roles, @video, fn devices ->
      {code, join_url} = host_game(devices.host)

      join_everyone(devices, code, join_url)

      devices.host
      |> assert_has("#player-count", text: "#{length(@players)}/#{WhoseJam.Game.max_players()}")
      |> click_button("Start game")

      pick_songs(devices)
      {scores, most_fooled} = play_every_round(devices)

      assert_final_scores(devices, scores)
      assert_awards(devices.host, most_fooled)
      # First place is held back for a couple of seconds, then the awards and
      # each phone's own result arrive; all of it needs long enough on film
      # to be read.
      Stage.hold(to_timeout(second: 3))
      Stage.snap(devices, [:host], "winner")
      Stage.hold(to_timeout(second: 4))
      Stage.snap(devices, [:host], "winner-card")
      Stage.hold(to_timeout(second: 6))
      everyone = Enum.map(@players, &elem(&1, 0))
      Stage.snap(devices, [:host | everyone], "final")
      Stage.hold(to_timeout(second: 1))
      exit_game(devices)
      Stage.hold(to_timeout(second: 2))
    end)
  end

  # --- lobby -----------------------------------------------------------------

  defp host_game(host) do
    host
    |> visit(~p"/")
    |> assert_connected()
    |> Stage.then_snap(:host, "home")
    |> click_button("Choose a theme")
    |> assert_has("h2", text: "Pick a theme")
    |> Stage.then_snap(:host, "themes")
    |> within("li:has(h3:text-is('#{@theme}'))", &click_button(&1, "Host this"))
    |> assert_has("p", text: "Room code")
    |> assert_connected()
    |> assert_has("#music-prompt-modal")
    # Once the dialog has finished fading in.
    |> Stage.then_hold(600)
    |> Stage.then_snap(:host, "music-prompt")
    # Mock Music needs no account: one click connects it, and the top bar
    # says so without a notice to dismiss.
    |> within("#music-prompt-modal", &click_button(&1, nil, "Connect", exact: true))
    |> refute_has("#music-prompt-modal")
    |> refute_has("[role=alert]")
    |> click_button("Settings")
    # The Mock player hook is running in this browser.
    |> assert_has("p", text: "This screen is ready to play the music.")
    |> fill_in("Time to pick songs", with: "120")
    |> fill_in("Prompts per player", with: "1")
    # Ten seconds of listening (the default). A made-up Mock song opens
    # voting early, when the TV's player reports its five seconds ended (so
    # those rounds prove the hook works); a real one plays on past it.
    |> fill_in("Listening, before the vote", with: "10")
    |> Stage.then_snap(:host, "settings")
    |> click_button("Close settings")

    "/host/" <> code = current_path(host)
    # The TV shows the address as someone would type it, without the scheme.
    shown = text_of(host, "#join-url")
    assert String.ends_with?(shown, "/play/#{code}")
    refute shown =~ "://"
    {code, "#{URI.parse(WhoseJamWeb.Endpoint.url()).scheme}://#{shown}"}
  end

  # Half the room follows the join link the TV shows (what its QR code
  # encodes), the other half types the room code on the home page.
  defp join_everyone(devices, code, join_url) do
    @players
    |> Enum.with_index()
    |> Enum.each(fn {{key, name, _device, _search, _song}, index} ->
      session = Map.fetch!(devices, key)

      session =
        if rem(index, 2) == 0 do
          visit(session, join_url)
        else
          session
          |> visit(~p"/")
          |> assert_connected()
          |> type("input[name=code]", code, delay: 90)
          |> snap_if(index == 1, key, "home-phone")
          |> click_button(nil, "Join", exact: true)
        end

      session
      |> assert_has("h1", text: "Pick a name")
      |> assert_connected()
      |> type("input[name=name]", name, delay: 90)
      |> snap_if(index == 0, key, "pick-name")
      |> click_button("Join game")
      |> assert_has("h1", text: "You’re in, #{name}")
      |> hold_if(index == 0, 500)
      |> snap_if(index == 0, key, "joined")

      assert_has(devices.host, "#lobby-players li", text: name)
    end)

    # Once the last seat has finished landing.
    Stage.hold(600)
    Stage.snap(devices, [:host, :ben, :eli, :gus], "lobby")
  end

  # --- answering -------------------------------------------------------------

  # Everyone searches at once, like a real room. The last pick ends the
  # answering phase, so a phone may skip straight past "Song picked"; the first
  # round's "Round 1 of 8" is what proves all eight picks landed.
  defp pick_songs(devices) do
    # The first player picks alone, so the stills catch the search before
    # anyone else has picked.
    [{first, _name, _device, search, song} | others] = @players

    devices
    |> Map.fetch!(first)
    |> assert_has("input[name=q]", timeout: @wait)

    assert_has(devices.host, "h1", text: "Heads down", timeout: @wait)
    Stage.hold(500)
    Stage.snap(devices, [:host, first, :gus], "pick-song")

    devices
    |> Map.fetch!(first)
    |> type("input[name=q]", search, delay: 90)
    |> assert_has("button", text: song)
    |> Stage.then_hold(400)
    |> Stage.then_snap(first, "search-results")
    |> click_button(song)
    |> Stage.then_hold(800)

    Stage.snap(devices, [:host, first], "song-picked")

    in_parallel(others, fn {key, _name, _device, search, song} ->
      devices
      |> Map.fetch!(key)
      |> assert_has("input[name=q]", timeout: @wait)
      |> type("input[name=q]", search, delay: 90)
      |> click_button(song)
    end)
  end

  # --- playing ---------------------------------------------------------------

  # Each round: read the song off the TV, have every other player vote (some
  # right, some fooled), check the TV reveals the submitter, and keep a tally of
  # the points the rules should award (and of the most players any one song
  # fooled, for the awards).
  defp play_every_round(devices) do
    initial = Map.new(@players, fn {key, _, _, _, _} -> {key, 0} end)

    Enum.reduce(1..@rounds, {initial, 0}, fn round, {scores, most_fooled} ->
      devices.host
      |> assert_has("p", text: "Round #{round} of #{@rounds}", timeout: @wait)

      song = text_of(devices.host, "h1")
      {submitter, submitter_name, _, _, _} = List.keyfind!(@players, song, 4)
      votes = votes_for(round, submitter)
      first? = round == 1

      # The round's card, then the song once the card has cleared.
      if first? do
        Stage.hold(600)
        Stage.snap(devices, [:host], "round-card")
        Stage.hold(2_900)
        listener = votes |> hd() |> elem(0)
        Stage.snap(devices, [:host, listener, submitter], "listening")
      end

      if round == 1 do
        devices.dev
        |> evaluate(
          "matchMedia('(prefers-reduced-motion: reduce)').matches",
          &assert(&1 == true)
        )
        |> evaluate(@watch_outcome)
      end

      # A guess-who round says what the song was picked for, on the TV and
      # the phones alike.
      prompt = text_of(devices.host, "#round-prompt blockquote")

      # The picker's phone keeps everyone's layout (the same names, button
      # and locked-in screen), but asks them their own question: whom the
      # room will wrongly blame for their song. What they lock in is no vote:
      # it is their prediction, worth a point when it comes true.
      bluff = picker_guess(round, submitter)

      devices
      |> Map.fetch!(submitter)
      |> assert_has("#phone-voting h1",
        text: "Who’ll get the blame?",
        timeout: @wait
      )
      |> assert_has("#vote-hint",
        text: "Predict the most popular wrong guess. +1 if you call it."
      )
      |> assert_has("#round-prompt blockquote", text: prompt)
      |> refute_has("#phone-voting button", text: submitter_name, exact: true)
      |> snap_if(first?, submitter, "picker-vote")
      |> click_button(nil, name_of(bluff), exact: true)
      |> click_button("Lock in #{name_of(bluff)}")
      |> assert_has("#phone-voted h1", text: name_of(bluff), exact: true)
      |> assert_has("#locked-note", text: "Your prediction")
      |> refute_has("#phone-voted", text: "ecoy")
      |> hold_if(first?, 500)
      |> snap_if(first?, submitter, "picker-locked")

      # In the first round one voter goes first, alone, for the stills.
      {lead, rest} = if first?, do: Enum.split(votes, 1), else: {[], votes}
      Enum.each(lead, &cast_vote(devices, &1, true))
      if first?, do: Stage.snap(devices, [:host], "tv-voting")
      in_parallel(rest, &cast_vote(devices, &1, false))

      # The TV shows who is in on the score strip, the picker among them
      # (everyone has something to lock in, so it gives nobody away): their
      # tape lands on their seat.
      devices.host
      |> assert_has("#vote-progress", text: "#{length(@players)} of #{length(@players)}")
      |> assert_has("#score-strip li[data-in] .jam-tape", text: submitter_name, exact: true)

      devices.host
      |> assert_has("p", text: "It was", timeout: @wait)
      |> assert_has("p.font-display", text: submitter_name)

      if first?, do: snap_reveal(devices, submitter, votes)

      assert_reveal(devices, submitter, votes, bluff)

      # Less motion is no head start: Dev's result still waited for the TV's
      # name (it arrived unseen, and faded in on the same beat as everyone's).
      if round == 1,
        do: evaluate(devices.dev, "window.firstOutcomeOpacity", &assert(&1 == "0"))

      # The default screen choices: the last reveal keeps the totals for the
      # final scores, and says so on the strip.
      if round == @rounds,
        do: assert_has(devices.host, "#strip-label", text: "final scores next")

      fooled = Enum.count(votes, fn {_voter, choice} -> choice != submitter end)
      {tally(scores, submitter, votes, bluff), max(most_fooled, fooled)}
    end)
  end

  defp cast_vote(devices, {voter, choice}, snap?) do
    {_, voter_name, _, _, _} = List.keyfind!(@players, voter, 0)
    {_, choice_name, _, _, _} = List.keyfind!(@players, choice, 0)

    devices
    |> Map.fetch!(voter)
    |> assert_has("#phone-voting h1", text: "Whose jam is this?", timeout: @wait)
    # Nobody is offered their own name.
    |> refute_has("#phone-voting button", text: voter_name, exact: true)
    # A tap chooses; locking it in is the vote.
    |> assert_has("#vote-hint", text: "Pick who you think chose it. +1 if you’re right.")
    |> refute_has("#phone-voting", text: "blame")
    |> snap_if(snap?, voter, "vote")
    |> click_button(nil, choice_name, exact: true)
    |> hold_if(snap?, 400)
    |> snap_if(snap?, voter, "vote-chosen")
    |> click_button("Lock in #{choice_name}")
    # The phone says back what was picked.
    |> assert_has("#phone-voted h1", text: choice_name, exact: true)
    |> assert_has("#locked-note", text: "Locked in")
    |> hold_if(snap?, 500)
    |> snap_if(snap?, voter, "vote-locked")

    :ok
  end

  # Once every beat of the reveal has landed: the TV, the picker's phone, and
  # the phones of one voter who called it and one who was fooled.
  defp snap_reveal(devices, submitter, votes) do
    right = Enum.find_value(votes, fn {voter, choice} -> choice == submitter && voter end)
    fooled = Enum.find_value(votes, fn {voter, choice} -> choice != submitter && voter end)
    Stage.hold(4_500)

    Stage.snap(
      devices,
      Enum.reject([:host, submitter, right, fooled], &(&1 in [nil, false])),
      "reveal"
    )
  end

  # The reveal groups the votes by who was named, sums the round up in two
  # lines, and each phone says what the round meant for its own player.
  defp assert_reveal(devices, submitter, votes, bluff) do
    for vote <- votes, do: assert_guess_shown(devices, submitter, vote)

    fooled = for {voter, choice} <- votes, choice != submitter, do: voter
    assert_verdict(devices.host, length(votes) - length(fooled), fooled)

    outcome = if fooled == [], do: "Nobody fell for it", else: "You fooled"
    phone = Map.fetch!(devices, submitter)
    assert_has(phone, "#my-outcome", text: outcome)

    # The picker's prediction is said on the TV and on their phone, right or
    # not; one that came true is a point of its own.
    if guessed_right?(submitter, votes, bluff) do
      # (A tie for the most wrong guesses names every one of them.)
      devices.host
      |> assert_has("#forecast", text: "+1")
      |> assert_has("#forecast", text: ", and called it")
      |> assert_has("#forecast", text: name_of(bluff))

      phone
      |> assert_has("#my-blame", text: "+1 for predicting ")
      |> assert_has("#my-blame", text: name_of(bluff))
    else
      assert_missed_guess(devices.host, phone, name_of(bluff), fooled)
    end
  end

  # A prediction that missed is said only when somebody got a wrong guess.
  defp assert_missed_guess(_host, _phone, _guess, []), do: :ok

  defp assert_missed_guess(host, phone, guess, _fooled) do
    # A miss is said plainly, with no points to it.
    host
    |> assert_has("#forecast", text: "Predicted #{guess}, but ")
    |> assert_has("#forecast", text: "took the blame")
    |> refute_has("#forecast", text: "+")

    assert_has(phone, "#my-blame", text: "Predicted #{guess}, but ")
  end

  # The TV's card for the player this voter named lists the voter (the right
  # one is headed "N called it"), and the voter's own phone says how their
  # guess went.
  defp assert_guess_shown(devices, submitter, {voter, choice}) do
    heading = if choice == submitter, do: " called it$", else: " said #{name_of(choice)}$"

    assert_has(
      devices.host,
      "#room-said li:has(span:text-matches('#{heading}'))",
      text: name_of(voter)
    )

    phone = Map.fetch!(devices, voter)

    if choice == submitter do
      assert_has(phone, "#my-outcome", text: "You called it")
    else
      phone
      |> assert_has("#my-outcome", text: "#{name_of(submitter)} got you")
      |> assert_has("#my-outcome", text: "You said #{name_of(choice)}")
    end
  end

  # Two lines, the same every round: what the picker made of it (naming up to
  # three fooled players), then how the room did.
  defp assert_verdict(host, right, fooled) do
    host
    |> assert_has("#reveal-summary", text: picker_line(right, length(fooled)))

    if length(fooled) <= 3 do
      for voter <- fooled, do: assert_has(host, "#reveal-summary", text: name_of(voter))
    end
  end

  defp picker_line(_right, 0), do: "Everyone saw through it."
  defp picker_line(_right, wrong) when wrong <= 3, do: "+#{wrong}"
  defp picker_line(right, wrong), do: "Fooled #{wrong} of #{right + wrong}"

  defp name_of(key) do
    {_, name, _, _, _} = List.keyfind!(@players, key, 0)
    name
  end

  # Deterministic but mixed: every voter is fooled in some rounds, some far
  # more often than others (so the game usually has a winner), and a fooled
  # voter names the next player along (never themselves).
  defp votes_for(round, submitter) do
    keys = Enum.map(@players, &elem(&1, 0))

    keys
    |> Enum.with_index()
    |> Enum.reject(fn {voter, _index} -> voter == submitter end)
    |> Enum.map(fn {voter, index} ->
      if rem(index + round, 2 + rem(index, 4)) == 0 do
        {voter, decoy(keys, submitter, voter)}
      else
        {voter, submitter}
      end
    end)
  end

  defp decoy(keys, submitter, voter) do
    keys
    |> Stream.cycle()
    |> Stream.drop_while(&(&1 != submitter))
    |> Stream.drop(1)
    |> Enum.find(&(&1 != voter and &1 != submitter))
  end

  # Who the picker says the room will blame: usually the player the fooled
  # voters name (so the guess often comes true), and every third round the
  # player before the picker (whom nobody names).
  defp picker_guess(round, submitter) do
    keys = Enum.map(@players, &elem(&1, 0))

    if rem(round, 3) == 0 do
      decoy(Enum.reverse(keys), submitter, submitter)
    else
      decoy(keys, submitter, submitter)
    end
  end

  # The picker guessed right when the player they named took the most wrong
  # votes (alone or level with another).
  defp guessed_right?(submitter, votes, bluff) do
    blamed =
      votes
      |> Enum.reject(fn {_voter, choice} -> choice == submitter end)
      |> Enum.frequencies_by(fn {_voter, choice} -> choice end)

    case blamed[bluff] do
      nil -> false
      count -> count == blamed |> Map.values() |> Enum.max()
    end
  end

  # The scoring rules, from the players' side: +1 for naming the submitter;
  # the submitter gets +1 for every player they fooled, and +1 more for
  # guessing who the room would blame.
  defp tally(scores, submitter, votes, bluff) do
    scores =
      Enum.reduce(votes, scores, fn
        {voter, ^submitter}, acc -> Map.update!(acc, voter, &(&1 + 1))
        {_voter, _decoy}, acc -> Map.update!(acc, submitter, &(&1 + 1))
      end)

    if guessed_right?(submitter, votes, bluff),
      do: Map.update!(scores, submitter, &(&1 + 1)),
      else: scores
  end

  # --- finished --------------------------------------------------------------

  # Players on the same score share a place, on the TV and on their phones.
  defp assert_final_scores(devices, scores) do
    devices.host
    |> assert_has("p", text: "Final scores", timeout: @wait)

    board =
      @players
      |> Enum.map(fn {key, name, _, _, _} -> %{id: key, name: name} end)
      |> Standings.rank(scores)

    for row <- board do
      place = Standings.ordinal(row.rank)

      devices.host
      |> assert_has("#final-scores li:has-text('#{row.name}') span.font-display",
        text: Integer.to_string(row.score),
        exact: true
      )
      |> assert_has("#final-scores li:has-text('#{row.name}')", text: place)

      devices
      |> Map.fetch!(row.id)
      |> assert_has("h1#my-place", text: finish_line(row, place), exact: true)
    end
  end

  defp finish_line(%{rank: 1, tied?: false}, _place), do: "You won"
  defp finish_line(%{rank: 1, tied?: true}, _place), do: "You tied for the win"
  defp finish_line(%{tied?: true}, place), do: "You tied for #{place}"
  defp finish_line(_row, place), do: "You finished #{place}"

  # The final screen remembers the best bluff: the most players one song
  # fooled, when that was more than one.
  defp assert_awards(host, most_fooled) when most_fooled <= 1,
    do: refute_has(host, "#awards dt", text: "Best bluff")

  defp assert_awards(host, most_fooled) do
    host
    |> assert_has("#awards dt", text: "Best bluff")
    |> assert_has("#awards dd", text: "fooled #{most_fooled}")
  end

  # The host closes the room from the final scoreboard (its confirmation is
  # accepted): the TV signs off with a closing card and stays on it, with the
  # way to host the next game, and every phone is told the game is over
  # while keeping its final scores.
  defp exit_game(devices) do
    devices.host
    |> click_button("Exit game")
    |> assert_has("#closing-card h1", text: "Thanks for playing", timeout: @wait)

    in_parallel(@players, fn {key, _name, _device, _search, _song} ->
      devices
      |> Map.fetch!(key)
      |> assert_has("#game-ended", text: "That’s the night.", timeout: @wait)
      # The final scores stay on screen.
      |> assert_has("h1#my-place")
      |> assert_has("#final-scores li", count: length(@players))
    end)

    Stage.hold(to_timeout(second: 1))
    Stage.snap(devices, [:host, :ava, :fern], "closing")
    Stage.hold(to_timeout(second: 2))

    # The next game starts from the closing card, with the themes to choose.
    devices.host
    |> click_link("Host another game")
    |> assert_has("h2", text: "Pick a theme", timeout: @wait)
  end

  # --- helpers ---------------------------------------------------------------

  # A still for the record (`Stage.snap/3`), when `snap?` says this is the
  # moment to take it.
  defp snap_if(session, true, key, name), do: Stage.then_snap(session, key, name)
  defp snap_if(session, false, _key, _name), do: session

  # Lets a tap's transition finish before a still (`Stage.then_hold/2`).
  defp hold_if(session, true, ms), do: Stage.then_hold(session, ms)
  defp hold_if(session, false, _ms), do: session

  # Interact only once LiveView has connected, or events are lost.
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

  # A failure in a linked task would kill the test process before
  # `Stage.record/4` could close the browsers and write the video, so each
  # worker returns its failure; once all have finished, the first is re-raised
  # here, in the test process.
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
