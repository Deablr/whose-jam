defmodule WhoseJamWeb.E2E.Stage do
  @moduledoc """
  Opens one recorded Playwright browser session per device for a browser
  end-to-end test, then stitches the recordings into a single video.

  Each device gets its own browser context, so its own cookie jar: every phone
  is a separate player, exactly as at a real party. Contexts emulate the
  device's viewport, pixel ratio, touch and user agent, record a video, and
  wear a small caption naming who is holding the device (an overlay with
  `pointer-events: none`, so it never intercepts a click).

  `record/4` runs the test body, then closes every context (which finalises
  its video) and lays the recordings out on one 1920×1080 canvas with
  `WhoseJamWeb.E2E.Video` — even when the body fails, so a failing run still
  leaves a video to watch.

  Before the body runs, every screen flashes white at the same instant. A
  recording starts whenever its page first paints, not when its browser opens,
  so that flash is what the recordings are lined up on; the combined video
  starts just after it.
  """

  alias PhoenixTest.Playwright
  alias PlaywrightEx.BrowserContext
  alias WhoseJamWeb.E2E.Video

  @typedoc """
  A device preset name (a key of `@devices` in this module), or a preset with
  overrides: `{preset, reduced_motion?: true}` asks the page for less motion
  (`prefers-reduced-motion: reduce`), as a phone set up that way would.
  """
  @type device :: atom() | {atom(), [{:reduced_motion?, boolean()}]}

  @typedoc "`{key, caption, device}` — `key` names the session in the map passed to the body."
  @type role :: {atom(), String.t(), device()}

  # kind: which layout slot the device takes. viewport is in CSS pixels.
  @devices %{
    tv: %{
      name: "TV",
      kind: :host,
      viewport: {1920, 1080},
      scale: 1.0,
      mobile?: false,
      user_agent: :default
    },
    iphone_15: %{
      name: "iPhone 15",
      kind: :phone,
      viewport: {393, 852},
      scale: 3.0,
      mobile?: true,
      user_agent:
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    },
    pixel_8: %{
      name: "Pixel 8",
      kind: :phone,
      viewport: {412, 915},
      scale: 2.625,
      mobile?: true,
      user_agent:
        "Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
    },
    iphone_se: %{
      name: "iPhone SE",
      kind: :phone,
      viewport: {375, 667},
      scale: 2.0,
      mobile?: true,
      user_agent:
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    },
    galaxy_s24: %{
      name: "Galaxy S24",
      kind: :phone,
      viewport: {360, 780},
      scale: 3.0,
      mobile?: true,
      user_agent:
        "Mozilla/5.0 (Linux; Android 14; SM-S921B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
    },
    ipad_mini: %{
      name: "iPad mini",
      kind: :tablet,
      viewport: {768, 1024},
      scale: 2.0,
      mobile?: true,
      user_agent:
        "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    },
    galaxy_tab_s9: %{
      name: "Galaxy Tab S9",
      kind: :tablet,
      viewport: {800, 1280},
      scale: 2.0,
      mobile?: true,
      user_agent:
        "Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    },
    macbook_air: %{
      name: "MacBook Air",
      kind: :desktop,
      viewport: {1440, 900},
      scale: 2.0,
      mobile?: false,
      user_agent: :default
    },
    windows_laptop: %{
      name: "Windows laptop",
      kind: :desktop,
      viewport: {1366, 768},
      scale: 1.0,
      mobile?: false,
      user_agent: :default
    }
  }

  # Where each kind of device sits on the 1920×1080 canvas, as {x, y, w, h}:
  # the TV top-left, phones in a 2×2 column on the right, tablets and laptops
  # along the bottom. Devices take their kind's slots in the order given.
  @canvas {1920, 1080}
  @slots %{
    host: [{0, 0, 1280, 720}],
    phone: [
      {1280, 0, 320, 540},
      {1600, 0, 320, 540},
      {1280, 540, 320, 540},
      {1600, 540, 320, 540}
    ],
    tablet: [{0, 720, 270, 360}, {270, 720, 270, 360}],
    desktop: [{540, 720, 370, 360}, {910, 720, 370, 360}]
  }

  # Recordings longer than this on either side are scaled down; the canvas
  # tiles are far smaller anyway.
  @max_video_side 1280
  @close_timeout to_timeout(second: 30)
  @flash_ms 500
  # Long enough for the instruction to reach all nine browsers first.
  @flash_lead_ms 1_000
  @caption_px 14

  @doc """
  Opens a recorded session for each role, runs `fun` with a map of
  `key => session`, then writes the combined video to `video_path`.

  `context` is the ExUnit test context (it carries the Playwright browser).
  Raw per-device recordings go to a directory next to `video_path`.
  """
  @spec record(map(), [role()], Path.t(), (%{atom() => Playwright.t()} -> any())) :: :ok
  def record(context, roles, video_path, fun) when is_function(fun, 1) do
    video_path = Path.expand(video_path)
    raw_dir = Path.rootname(video_path)
    File.rm_rf!(raw_dir)
    # A failed run must never leave the previous run's video looking current.
    File.rm(video_path)

    started_ms = System.monotonic_time(:millisecond)
    stage = Enum.map(assign_slots(roles), &open(&1, raw_dir, started_ms, context))
    sessions = Map.new(stage, &{&1.key, &1.session})
    flash(stage)

    try do
      fun.(sessions)
    catch
      kind, reason ->
        # Keep the test's own failure; a video problem only warns here.
        stacktrace = __STACKTRACE__
        finish(stage, video_path, fn error -> IO.warn("no game video: #{error}") end)
        :erlang.raise(kind, reason, stacktrace)
    else
      _ -> finish(stage, video_path, &raise/1)
    end
  end

  @doc """
  Keeps every screen as it is for `ms`, so the video shows a screen the test
  would otherwise leave at once (the final scoreboard, before the host exits).

  Only for the recording. Never wait for the app with it: nothing has changed
  when it returns, so assert on what the screen shows instead.
  """
  @spec hold(non_neg_integer()) :: :ok
  def hold(ms) when is_integer(ms) and ms >= 0 do
    # A pause for the camera, not a wait: there is no event to receive
    # instead, and no assertion depends on it.
    # credo:disable-for-next-line WhoseJam.Credo.Checks.NoSleepInTests
    Process.sleep(ms)
  end

  @doc """
  `hold/1` in the middle of a pipeline: keeps every screen as it is for `ms`,
  then hands `session` on. Only for the recording, as `hold/1` is.
  """
  @spec then_hold(Playwright.t(), non_neg_integer()) :: Playwright.t()
  def then_hold(session, ms) do
    hold(ms)
    session
  end

  defp finish(stage, video_path, on_error) do
    stage
    |> Task.async_stream(&close/1, timeout: :infinity)
    |> Stream.run()

    try do
      {tiles, skip_ms} = stage |> Enum.map(&tile/1) |> align()
      Video.compose!(tiles, @canvas, video_path, skip_ms)
      IO.puts("\nGame video: #{Path.relative_to_cwd(video_path)}")
    rescue
      error -> on_error.(Exception.message(error))
    end

    :ok
  end

  # Puts a white screen on every device at the same instant, for half a
  # second: the mark align/1 looks for. Every browser is told the moment to do
  # it (they share this machine's clock) rather than told to do it now, so it
  # doesn't matter that the nine calls land a few frames apart.
  defp flash(stage) do
    at_ms = System.os_time(:millisecond) + @flash_lead_ms
    script = flash_script(at_ms)

    stage
    |> Task.async_stream(&Playwright.evaluate(&1.session, script), timeout: :infinity)
    |> Stream.run()

    # Let it happen before the game starts painting over it.
    hold(max(at_ms + @flash_ms - System.os_time(:millisecond), 0))
  end

  defp flash_script(at_ms) do
    """
    (() => {
      const flash = () => {
        const el = document.createElement("div");
        el.style.cssText = "position:fixed;inset:0;z-index:2147483646;background:#fff";
        document.documentElement.appendChild(el);
        setTimeout(() => el.remove(), #{@flash_ms});
      };
      setTimeout(flash, Math.max(0, #{at_ms} - Date.now()));
    })();
    """
  end

  # Holds each recording back so that every flash ends at the same moment
  # (the recording whose flash ends latest started first, and is not held
  # back at all), and says how much of the combined video to skip so it starts
  # once the flash is over. A recording with no flash to be found keeps the
  # moment its device opened, as before.
  defp align(tiles) do
    flashes = Map.new(tiles, &{&1.path, Video.flash_end(&1.path)})

    case flashes |> Map.values() |> Enum.reject(&is_nil/1) do
      [] ->
        {tiles, 0}

      found ->
        latest = Enum.max(found)

        {Enum.map(tiles, &hold_back(&1, Map.fetch!(flashes, &1.path), latest)),
         round(latest * 1000) + 200}
    end
  end

  defp hold_back(tile, nil, _latest), do: tile
  defp hold_back(tile, flash, latest), do: %{tile | offset_ms: round((latest - flash) * 1000)}

  defp assign_slots(roles) do
    {placed, _free} =
      Enum.map_reduce(roles, @slots, fn {key, caption, device}, free ->
        spec = device_spec(device)

        case Map.fetch!(free, spec.kind) do
          [slot | rest] ->
            {%{key: key, caption: caption, spec: spec, slot: slot},
             Map.put(free, spec.kind, rest)}

          [] ->
            raise ArgumentError, "no free layout slot for another #{spec.kind} (#{inspect(key)})"
        end
      end)

    placed
  end

  defp device_spec({preset, overrides}),
    do: Map.merge(device_spec(preset), Map.new(overrides))

  defp device_spec(preset), do: Map.fetch!(@devices, preset)

  defp open(role, raw_dir, started_ms, context) do
    dir = Path.join(raw_dir, Atom.to_string(role.key))
    File.mkdir_p!(dir)

    config = Playwright.Config.validate!(browser_context_opts: context_opts(role.spec, dir))
    session = Playwright.Case.new_session(config, context)
    caption = "#{role.caption} · #{role.spec.name}"
    script = caption_script(caption, caption_px(role.spec, role.slot))

    case BrowserContext.add_init_script(session.context_id,
           source: script,
           timeout: Playwright.Config.global(:timeout)
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "couldn't caption #{caption}: #{inspect(reason)}"
    end

    # A recording starts at the page's first paint, not when the context
    # opens, so paint the blank page now: every video then starts at a known
    # moment and the tiles line up.
    offset_ms = System.monotonic_time(:millisecond) - started_ms
    Playwright.evaluate(session, script)

    Map.merge(role, %{session: session, dir: dir, offset_ms: offset_ms})
  end

  defp context_opts(spec, dir) do
    {width, height} = spec.viewport
    shrink = min(1.0, @max_video_side / max(width, height))

    opts = [
      viewport: %{width: width, height: height},
      device_scale_factor: spec.scale,
      is_mobile: spec.mobile?,
      has_touch: spec.mobile?,
      record_video: %{
        dir: dir,
        size: %{width: round(width * shrink), height: round(height * shrink)}
      }
    ]

    opts =
      if spec[:reduced_motion?], do: Keyword.put(opts, :reduced_motion, "reduce"), else: opts

    case spec.user_agent do
      :default -> opts
      user_agent -> Keyword.put(opts, :user_agent, user_agent)
    end
  end

  # Size the caption so it reads at about @caption_px once the recording is
  # shrunk into its tile (a laptop tile is a quarter of the laptop's width).
  defp caption_px(%{viewport: {width, height}}, {_x, _y, tile_w, tile_h}) do
    shrink = min(tile_w / width, tile_h / height)
    max(@caption_px, round(@caption_px / shrink))
  end

  defp caption_script(caption, font_px) do
    """
    (() => {
      const show = () => {
        if (document.getElementById("e2e-device-caption")) return;
        const el = document.createElement("div");
        el.id = "e2e-device-caption";
        el.textContent = #{Jason.encode!(caption)};
        el.style.cssText = "position:fixed;left:.5em;bottom:.5em;z-index:2147483647;" +
          "pointer-events:none;padding:.25em .75em;border-radius:999px;" +
          "background:rgba(18,7,38,.85);color:#fbf1e1;font:600 #{font_px}px system-ui,sans-serif;";
        document.documentElement.appendChild(el);
        // The blank page before the first visit: paint it in the game's ink.
        if (location.href === "about:blank") document.documentElement.style.background = "#120726";
      };
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", show);
      } else {
        show();
      }
    })();
    """
  end

  defp close(%{session: session}) do
    # Closing the context finishes writing its video. A context the test
    # already closed reports an error, which is fine to ignore here.
    _ = BrowserContext.close(session.context_id, timeout: @close_timeout)
    :ok
  end

  defp tile(%{dir: dir, slot: slot, offset_ms: offset_ms, caption: caption}) do
    case Path.wildcard(Path.join(dir, "*.webm")) do
      [video] ->
        %{path: video, offset_ms: offset_ms, rect: slot}

      other ->
        raise "expected one recording for #{caption} in #{dir}, found #{inspect(other)}"
    end
  end
end
