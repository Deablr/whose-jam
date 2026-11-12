defmodule WhoseJamWeb.E2E.FullGameTest do
  # One whole party, in real browsers: a host on the TV and eight players on
  # phones, tablets and laptops play a full game against the real server and a
  # real Postgres (see `mix test.e2e`). Only the music service is fake (the
  # Mock provider). Every device is recorded and the run leaves one combined
  # video at @video.
  use PhoenixTest.Playwright.Case, async: false
  use WhoseJamWeb, :verified_routes

  alias WhoseJamWeb.E2E.Stage

  @moduletag :e2e
  @moduletag timeout: to_timeout(minute: 10)

  @video "tmp/e2e/full_game.mp4"
  @theme "Certified Bangers"
  @wait to_timeout(second: 30)

  # {key, name, device, search typed, song picked}. Each player picks a
  # different Mock track, so a song identifies its submitter.
  @players [
    {:ava, "Ava", :iphone_15, "neon", "Neon Overdrive"},
    {:ben, "Ben", :pixel_8, "paper", "Paper Planes at Midnight"},
    {:cleo, "Cleo", :iphone_se, "slow burn", "Slow Burn Sunday"},
    {:dev, "Dev", :galaxy_s24, "concrete", "Concrete Garden"},
    {:eli, "Eli", :ipad_mini, "rewind", "Rewind to Summer"},
    {:fern, "Fern", :galaxy_tab_s9, "static", "Static in the Stars"},
    {:gus, "Gus", :macbook_air, "karaoke", "Backseat Karaoke"},
    {:hana, "Hana", :windows_laptop, "golden", "Golden Hour Hangover"}
  ]

  # One question each, so one round per player.
  @rounds length(@players)

  setup do
    # config/test.exs shortens the reveal to a blink. Hold it long enough to
    # read in the video and for the per-round reveal assertions to see it.
    previous = Application.fetch_env!(:whose_jam, :results_pause_ms)
    Application.put_env(:whose_jam, :results_pause_ms, 4_000)
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
      |> assert_has("p", text: "Players #{length(@players)}/8")
      |> click_button("Start game")

      pick_songs(devices)
      scores = play_every_round(devices)

      assert_final_scores(devices, scores)
    end)
  end

  # --- lobby -----------------------------------------------------------------

  defp host_game(host) do
    host
    |> visit(~p"/")
    |> assert_connected()
    |> click_button("Choose a vibe")
    |> within("li:has(h3:text-is('#{@theme}'))", &click_button(&1, "Host this"))
    |> assert_has("p", text: "Room code")
    |> assert_connected()
    # Mock Music needs no account: one click connects it.
    |> within("#music-prompt-modal", &click_button(&1, nil, "Connect", exact: true))
    # Dismiss the "connected" toast; it sits over the top bar.
    |> click("[role=alert]", "Mock Music connected.")
    |> refute_has("[role=alert]")
    |> click_button("Settings")
    # The Mock player hook is running in this browser.
    |> assert_has("p", text: "Player is live on this screen.")
    |> fill_in("Answer timer (s)", with: "120")
    |> fill_in("Questions per player", with: "1")
    # The longest listening delay: voting then opens only when the TV's player
    # reports the 5s Mock track ended, so every round proves the hook works.
    |> fill_in("Listen before voting opens (s)", with: "60")
    |> click_button("Close settings")

    "/host/" <> code = current_path(host)
    join_url = text_of(host, "p > span.font-bold")
    assert String.ends_with?(join_url, "/play/#{code}")
    {code, join_url}
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
          |> click_button(nil, "Join", exact: true)
        end

      session
      |> assert_has("h1", text: "Pick a name")
      |> assert_connected()
      |> type("input[name=name]", name, delay: 90)
      |> click_button("Join the party")
      |> assert_has("h1", text: "You're in, #{name}!")

      assert_has(devices.host, ".jam-chip", text: name)
    end)
  end

  # --- answering -------------------------------------------------------------

  # Everyone searches at once, like a real room. The last pick ends the
  # answering phase, so a phone may skip straight past "Locked in"; the first
  # round's "Round 1 of 8" is what proves all eight picks landed.
  defp pick_songs(devices) do
    in_parallel(@players, fn {key, _name, _device, search, song} ->
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
  # the points the rules should award.
  defp play_every_round(devices) do
    initial = Map.new(@players, fn {key, _, _, _, _} -> {key, 0} end)

    Enum.reduce(1..@rounds, initial, fn round, scores ->
      devices.host
      |> assert_has("p", text: "Round #{round} of #{@rounds}", timeout: @wait)

      song = text_of(devices.host, "h1")
      {submitter, submitter_name, _, _, _} = List.keyfind!(@players, song, 4)
      votes = votes_for(round, submitter)

      devices
      |> Map.fetch!(submitter)
      |> assert_has("h1", text: "This one's yours", timeout: @wait)

      in_parallel(votes, fn {voter, choice} ->
        {_, choice_name, _, _, _} = List.keyfind!(@players, choice, 0)

        devices
        |> Map.fetch!(voter)
        |> assert_has("h1", text: "Who submitted this?", timeout: @wait)
        |> click_button(nil, choice_name, exact: true)
        |> assert_has("h1", text: "Vote locked in")
      end)

      devices.host
      |> assert_has("p", text: "It was", timeout: @wait)
      |> assert_has("p.font-display", text: submitter_name)

      tally(scores, submitter, votes)
    end)
  end

  # Deterministic but mixed: each voter guesses right two rounds in three and
  # otherwise names the next player along (never themselves).
  defp votes_for(round, submitter) do
    keys = Enum.map(@players, &elem(&1, 0))

    keys
    |> Enum.with_index()
    |> Enum.reject(fn {voter, _index} -> voter == submitter end)
    |> Enum.map(fn {voter, index} ->
      if rem(index + round, 3) == 0 do
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

  # The scoring rules, from the players' side: +1 for naming the submitter,
  # and the submitter gets +1 for every player they fooled.
  defp tally(scores, submitter, votes) do
    Enum.reduce(votes, scores, fn
      {voter, ^submitter}, acc -> Map.update!(acc, voter, &(&1 + 1))
      {_voter, _decoy}, acc -> Map.update!(acc, submitter, &(&1 + 1))
    end)
  end

  # --- finished --------------------------------------------------------------

  defp assert_final_scores(devices, scores) do
    devices.host
    |> assert_has("p", text: "Final scores", timeout: @wait)

    for {key, name, _device, _search, _song} <- @players do
      devices.host
      |> assert_has("li:has-text('#{name}') span.font-display",
        text: Integer.to_string(Map.fetch!(scores, key)),
        exact: true
      )

      devices
      |> Map.fetch!(key)
      |> assert_has("h1", text: "That's a wrap!")
    end
  end

  # --- helpers ---------------------------------------------------------------

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
