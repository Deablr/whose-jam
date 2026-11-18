defmodule WhoseJamWeb.E2E.FitTest do
  # Screens that hold whatever a room gives them: names as long as a name
  # may be, a long address to join at, and windows of every shape (a laptop
  # between sizes, a near-square monitor, an ultrawide TV). Nothing is cut
  # short and nothing runs off its ticket. A notice says its piece and then
  # gets out of the way. And the picker may predict that nobody falls for
  # their song, by naming themselves. In real browsers against the real
  # server (see `mix test.e2e`, which serves it at a long `.localhost`
  # address); only the music service is fake.
  use PhoenixTest.Playwright.Case, async: false
  use WhoseJamWeb, :verified_routes

  import WhoseJamWeb.E2E.Fit, only: [assert_whole: 3, assert_inside: 4]

  alias WhoseJamWeb.E2E.Fit
  alias WhoseJamWeb.E2E.Stage

  @moduletag :e2e
  @moduletag timeout: to_timeout(minute: 10)

  @theme "Certified Bangers"
  @wait to_timeout(second: 30)

  # Every shape a screen comes in, {width, height} in CSS pixels: phones and
  # a tablet, laptops between the layout's sizes, square-ish monitors, 16:9
  # TVs (720p to 4K) and an ultrawide.
  @home_sizes [
    {360, 740},
    {768, 1024},
    {1024, 768},
    {1100, 1060},
    {1180, 820},
    {1280, 800},
    {1366, 768},
    {1440, 1400},
    {1920, 1080},
    {1980, 1900},
    {2560, 1080}
  ]

  # The TV's screen at every size a host might put it on.
  @tv_sizes [
    {1024, 768},
    {1100, 1060},
    {1280, 720},
    {1366, 768},
    {1920, 1080},
    {1980, 1900},
    {2560, 1080},
    {3840, 2160}
  ]

  # {key, name, device, [{search, song}, ...]}: names from as long as a name
  # may be (24 characters) down to four, two prompts each, so the TV counts
  # each player's picks beside their name.
  @players [
    {:max, "Maximiliana-Rose Johnson", :iphone_se,
     [{"neon", "Neon Overdrive"}, {"paper", "Paper Planes at Midnight"}]},
    {:chris, "Christopher", :galaxy_s24,
     [{"slow", "Slow Burn Sunday"}, {"concrete", "Concrete Garden"}]},
    {:jared, "Jared", :iphone_15,
     [{"rewind", "Rewind to Summer"}, {"static", "Static in the Stars"}]},
    {:deab, "deab", :pixel_8,
     [{"backseat", "Backseat Karaoke"}, {"golden", "Golden Hour Hangover"}]}
  ]

  setup do
    previous = Application.fetch_env!(:whose_jam, :results_pause_ms)
    Application.put_env(:whose_jam, :results_pause_ms, 8_000)
    on_exit(fn -> Application.put_env(:whose_jam, :results_pause_ms, previous) end)
  end

  # --- the room code -----------------------------------------------------------

  # The home page's join ticket keeps its placeholder, and a typed code in
  # its widest letters, whole at every size, including the laptop sizes
  # between the phone layout and the TV's; and on the smallest phone.
  test "the room code fits the join ticket on every screen", context do
    roles = [{:screen, "Any screen", :tv}, {:phone, "A phone", :iphone_se}]

    Stage.record(context, roles, "tmp/e2e/fit_home.mp4", fn devices ->
      devices.phone
      |> visit(~p"/")
      |> assert_connected()
      |> assert_join_ticket_fits(:iphone_se)

      screen = devices.screen |> visit(~p"/") |> assert_connected()

      for size <- @home_sizes do
        screen |> Fit.resize(size) |> assert_join_ticket_fits(size)
      end
    end)
  end

  # --- notices -----------------------------------------------------------------

  # A notice is read, then leaves on its own: on the TV, where nobody is
  # close enough to close it, and on a phone. (The TV's comes back from a
  # music sign-in, as "connected" does; this one is for a service that
  # doesn't sign in that way.)
  test "a notice says its piece, then clears itself", context do
    roles = [{:host, "Host", :tv}, {:ava, "Ava", :iphone_15}]

    Stage.record(context, roles, "tmp/e2e/fit_notices.mp4", fn devices ->
      {code, _join_url} = host_game(devices.host, prompts: 1)

      devices.host
      |> visit("/auth/mock?code=#{code}")
      |> assert_has("#flash-error", text: "connect this way", timeout: @wait)
      |> assert_connected()
      # Long enough on screen to read.
      |> Stage.then_hold(1_500)
      |> assert_has("#flash-error", text: "connect this way")
      |> refute_has("#flash-error", timeout: to_timeout(second: 15))

      devices.ava
      |> visit(~p"/")
      |> assert_connected()
      |> click_button(nil, "Join", exact: true)
      |> assert_has("#flash-error", text: "Enter a room code to join.")
      |> Stage.then_hold(1_500)
      |> assert_has("#flash-error", text: "Enter a room code to join.")
      |> refute_has("#flash-error", timeout: to_timeout(second: 15))
    end)
  end

  # --- long names, a long address, and a prediction of nobody --------------

  test "long names and a long address fit every screen; the picker can name themselves",
       context do
    roles = [{:host, "Host", :tv} | Enum.map(@players, fn {k, n, d, _} -> {k, n, d} end)]

    Stage.record(context, roles, "tmp/e2e/fit_names.mp4", fn devices ->
      {_code, join_url} = host_game(devices.host, prompts: 2)

      for {key, name, _device, _picks} <- @players do
        devices
        |> Map.fetch!(key)
        |> visit(join_url)
        |> assert_has("h1", text: "Pick a name", timeout: @wait)
        |> assert_connected()
        |> type("input[name=name]", name, delay: 30)
        |> click_button("Join game")
        |> assert_has("h1", text: "You’re in")
        |> assert_whole("#me", key)

        assert_has(devices.host, "#lobby-players li", text: name)
      end

      # The lobby: the code and the address on the ticket, every name whole.
      at_every_tv_size(devices.host, fn host, size ->
        host
        |> assert_inside("#join-url", ".jam-ticket", size)
        |> assert_inside("#lobby-code", ".jam-ticket", size)
        |> assert_whole("#lobby-players", size)
      end)

      devices.host
      |> Fit.resize({1920, 1080})
      |> click_button("Start game")
      |> assert_has("h1", text: "Heads down", timeout: @wait)

      # Picking, before anyone has picked: each name whole beside its count.
      assert_picking_fits(devices.host)

      # The longest name picks both songs and the next one of two, so the
      # TV shows a tape, a half-done count and untouched slots together.
      [{max, _, _, max_picks}, {chris, _, _, [chris_first, chris_second]} | others] = @players
      pick(devices, max, max_picks)
      pick(devices, chris, [chris_first])
      assert_has(devices.host, "#locked-in-count", text: "1/")
      assert_picking_fits(devices.host)

      # The header's ticket, on every screen while a game plays.
      at_every_tv_size(devices.host, fn host, size ->
        host
        |> assert_inside("#join-at", ".jam-ticket", size)
        |> assert_inside("#room-code", ".jam-ticket", size)
      end)

      Fit.resize(devices.host, {1920, 1080})

      # Everyone else picks, which ends the picking.
      pick(devices, chris, [chris_second], 1)
      for {key, _name, _device, picks} <- others, do: pick(devices, key, picks)

      play_first_round(devices)
    end)
  end

  # Every phone lists every player, its own name included, so the picker's
  # names are everyone's. The picker names themselves (nobody will fall for
  # it), everyone calls it, and the prediction comes true.
  defp play_first_round(devices) do
    # (Voting opens at once, so the song comes straight on, past the card.)
    devices.host
    |> assert_has("#round-prompt", timeout: @wait)

    song = devices.host |> text_of("h1") |> String.replace("\u00A0", " ")

    {submitter, submitter_name, _, _} =
      Enum.find(@players, fn {_, _, _, picks} -> Enum.any?(picks, &(elem(&1, 1) == song)) end)

    picker =
      devices
      |> Map.fetch!(submitter)
      |> assert_has("#phone-voting h1", text: "Who’ll get the blame?", timeout: @wait)

    for {key, name, _device, _picks} <- @players do
      devices
      |> Map.fetch!(key)
      |> assert_has("#phone-voting h1", timeout: @wait)
      |> assert_has("#phone-voting button[phx-value-choice]", count: length(@players))
      |> assert_has("#phone-voting button[phx-value-choice]", text: name, exact: true)
      |> assert_whole("#phone-voting", key)
    end

    picker
    |> click_button(nil, submitter_name, exact: true)
    |> click_button("Lock in #{submitter_name}")
    |> assert_has("#phone-voted h1", text: submitter_name, exact: true)
    |> assert_has("#locked-note", text: "Your prediction")
    |> assert_whole("#phone-voted", submitter)

    for {voter, _name, _device, _picks} <- @players, voter != submitter do
      devices
      |> Map.fetch!(voter)
      |> assert_has("#phone-voting h1", text: "Whose jam is this?", timeout: @wait)
      |> click_button(nil, submitter_name, exact: true)
      |> click_button("Lock in #{submitter_name}")
      |> assert_has("#phone-voted h1", text: submitter_name, exact: true)
    end

    devices.host
    |> assert_whole("#score-strip", :voting)
    |> assert_has("p", text: "It was", timeout: @wait)
    |> assert_has("#forecast", text: "Predicted nobody would fall for it")
    |> assert_has("#forecast", text: "+1")

    devices
    |> Map.fetch!(submitter)
    |> assert_has("#my-blame", text: "+1 for predicting nobody would fall for it")

    # Once the reveal has landed: the room's votes and the strip, whole.
    Stage.hold(4_500)

    at_every_tv_size(devices.host, fn host, size ->
      host
      |> assert_whole("#room-said", size)
      |> assert_whole("#score-strip", size)
    end)

    Fit.resize(devices.host, {1920, 1080})
  end

  # --- setting up --------------------------------------------------------------

  defp host_game(host, prompts: prompts) do
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
    |> fill_in("Time per question", with: "300")
    |> fill_in("Prompts per player", with: Integer.to_string(prompts))
    # Names as long as the host may allow, and every song played.
    |> fill_in("Longest name (letters)", with: "24")
    |> fill_in("Songs played (%)", with: "100")
    |> fill_in("Voting opens after", with: "0")
    |> click_button("Close settings")

    "/host/" <> code = current_path(host)
    shown = text_of(host, "#join-url")
    {code, "#{URI.parse(WhoseJamWeb.Endpoint.url()).scheme}://#{shown}"}
  end

  # Picks songs for a player's prompts in turn, starting at prompt
  # `skip + 1` (paging past the ones already picked).
  defp pick(devices, key, picks, skip \\ 0) do
    session = devices |> Map.fetch!(key) |> assert_has("[phx-click=next_q]", timeout: @wait)

    session =
      Enum.reduce(1..skip//1, session, fn _, session -> click_button(session, "Next →") end)

    picks
    |> Enum.with_index(1)
    |> Enum.reduce(session, fn {{search, song}, n}, session ->
      session
      |> assert_has("input[name=q]", timeout: @wait)
      |> type("input[name=q]", search, delay: 40)
      |> assert_has("button", text: song, timeout: @wait)
      |> click_button(song)
      |> then(&if(n < length(picks), do: click_button(&1, "Next →"), else: &1))
    end)
  end

  # --- fit checks --------------------------------------------------------------

  defp assert_picking_fits(host) do
    at_every_tv_size(host, fn host, size -> assert_whole(host, "#answering-players", size) end)
    Fit.resize(host, {1920, 1080})
  end

  defp at_every_tv_size(host, check) do
    Enum.reduce(@tv_sizes, host, fn size, host -> check.(Fit.resize(host, size), size) end)
  end

  defp assert_join_ticket_fits(session, size) do
    session
    |> assert_input_fits(size, "the placeholder")
    |> fill_in("Room code", with: "MWMW")
    |> assert_input_fits(size, "a typed code")
    |> fill_in("Room code", with: "")
    |> assert_whole("form[phx-submit=join]", size)
  end

  defp assert_input_fits(session, size, what) do
    %{"need" => need, "room" => room, "box" => box} = Fit.input_text(session, "input[name=code]")

    assert need <= room,
           "at #{inspect(size)} #{what} needs #{need}px, the room code input has #{room}px (#{box})"

    session
  end

  # --- helpers -----------------------------------------------------------------

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
end
