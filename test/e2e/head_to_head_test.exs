defmodule WhoseJamWeb.E2E.HeadToHeadTest do
  # A head-to-head game: three friends answer the same prompt, then their
  # songs meet two at a time (the third has a bye) until one is left. The
  # room votes for the better song of each matchup; a vote for one's own
  # doesn't count. In real browsers against the real server (see
  # `mix test.e2e`); only the music service is fake (made-up Mock songs,
  # which report their end after a few seconds, so each clip is short).
  use PhoenixTest.Playwright.Case, async: false
  use WhoseJamWeb, :verified_routes

  alias WhoseJamWeb.E2E.Stage

  @moduletag :e2e
  @moduletag timeout: to_timeout(minute: 10)

  @video "tmp/e2e/head_to_head.mp4"
  @theme "Head to Head"
  @wait to_timeout(second: 40)

  # {key, name, device, search, song}
  @players [
    {:ava, "Ava", :iphone_15, "neon", "Neon Overdrive"},
    {:ben, "Ben", :pixel_8, "slow", "Slow Burn Sunday"},
    {:cleo, "Cleo", :galaxy_s24, "concrete", "Concrete Garden"}
  ]

  setup do
    previous = Application.fetch_env!(:whose_jam, :results_pause_ms)
    Application.put_env(:whose_jam, :results_pause_ms, 6_000)
    on_exit(fn -> Application.put_env(:whose_jam, :results_pause_ms, previous) end)
  end

  test "three songs meet head to head until one is left", context do
    roles = [{:host, "Host", :tv} | Enum.map(@players, fn {k, n, d, _, _} -> {k, n, d} end)]

    Stage.record(context, roles, @video, fn devices ->
      join_url = host_game(devices.host)

      for {key, name, _device, _search, _song} <- @players do
        devices
        |> Map.fetch!(key)
        |> visit(join_url)
        |> assert_has("h1", text: "Pick a name", timeout: @wait)
        |> assert_connected()
        |> type("input[name=name]", name, delay: 40)
        |> click_button("Join game")
        |> assert_has("h1", text: "You’re in")
      end

      devices.host
      |> assert_has("#how-to-score", text: "for each vote your song wins head to head")
      |> click_button("Start game")

      pick_songs(devices)

      # Three songs: one matchup, and a bye to the final.
      matchup(devices, "Semi-final", "Through to the next round…", "Through")
      matchup(devices, "Final", "The winner is…", "Champion")

      devices.host
      |> assert_has("p", text: "Final scores", timeout: @wait)

      Stage.hold(to_timeout(second: 8))
      Stage.snap(devices, [:host, :ava], "vs-final")
    end)
  end

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
    |> fill_in("Time per question", with: "120")
    |> click_button("Close settings")

    shown = text_of(host, "#join-url")
    "#{URI.parse(WhoseJamWeb.Endpoint.url()).scheme}://#{shown}"
  end

  # Everyone answers the same prompt. The first to pick sees that they're
  # done, without their song on screen.
  defp pick_songs(devices) do
    prompts =
      for {key, _name, _device, search, song} <- @players do
        session = devices |> Map.fetch!(key) |> assert_has("input[name=q]", timeout: @wait)
        prompt = text_of(session, "h1")

        session
        |> type("input[name=q]", search, delay: 60)
        |> assert_has("button", text: song, timeout: @wait)
        |> click_button(song)

        prompt
      end

    assert length(Enum.uniq(prompts)) == 1

    devices.ava
    |> assert_has("#done-picking h1", text: "You’re done", timeout: @wait)
    |> refute_has("#done-picking", text: "Neon Overdrive")
  end

  # A matchup: the two songs play in turn, everyone votes for the first,
  # and the reveal names the pickers and the one that goes through.
  defp matchup(devices, stage, headline, tape) do
    devices.host
    |> assert_has("#tv-vs #round-prompt p", text: stage, timeout: @wait)
    |> assert_has("#tv-vs", text: "Song 1 of 2")
    |> Stage.then_hold(2_500)
    |> Stage.then_snap(:host, "vs-#{stage}-listening")

    devices.ava
    |> assert_has("#vs-listening", text: "is playing on the TV", timeout: @wait)

    for {key, _name, _device, _search, _song} <- @players do
      devices
      |> Map.fetch!(key)
      |> assert_has("#phone-voting h1", text: "Which is better?", timeout: @wait)
      |> assert_has("#vote-hint", text: "A vote for your own doesn’t count.")
      |> click_button("#vs-choice-a", "Song 1")
      |> click_button("Lock in song 1")
      |> assert_has("#locked-note", text: "Locked in")
    end

    Stage.snap(devices, [:host, :ben], "vs-#{stage}-voted")

    devices.host
    |> assert_has("#tv-vs p", text: headline, timeout: @wait)
    |> assert_has("#vs-side-a", text: tape)
    |> Stage.then_hold(1_500)
    |> Stage.then_snap(:host, "vs-#{stage}-result")

    # Two of the three votes count for song 1: its picker's own doesn't.
    assert_has(devices.host, "#vs-side-a", text: "2")
  end

  defp assert_connected(session), do: assert_has(session, "[data-phx-main].phx-connected")

  defp text_of(session, selector) do
    evaluate(
      session,
      "document.querySelector(#{Jason.encode!(selector)})?.textContent.trim()",
      &send(self(), {:text, &1})
    )

    assert_received {:text, text} when is_binary(text)
    text
  end
end
