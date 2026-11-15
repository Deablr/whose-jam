defmodule WhoseJamWeb.E2E.Fit do
  @moduledoc """
  Measures, in a browser end-to-end test, whether a screen's words fit the
  shapes they are set in: a name cut short on its tape, an address running
  off its ticket, a placeholder too wide for its input. Each check returns
  what doesn't fit (empty when everything does), so a test can assert on it
  and name the culprit when it fails.

  `resize/2` changes a device's viewport, so one session can be checked at
  every screen size a room might show it on.
  """

  alias PhoenixTest.Playwright
  alias PlaywrightEx.Frame

  @doc """
  Gives `session`'s page a viewport of `{width, height}` CSS pixels, then
  hands `session` on once the page has laid itself out at that size.
  """
  @spec resize(Playwright.t(), {pos_integer(), pos_integer()}) :: Playwright.t()
  def resize(session, {width, height}) do
    message = %{
      guid: session.page_id,
      method: :set_viewport_size,
      params: %{viewport_size: %{width: width, height: height}}
    }

    case PlaywrightEx.Connection.send(PlaywrightEx.Supervisor.Connection, message, timeout()) do
      %{error: error} -> raise "couldn't resize to #{width}×#{height}: #{inspect(error)}"
      _ok -> :ok
    end

    # Two frames: one to apply the size, one to lay out at it.
    run(
      session,
      "() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)))"
    )

    session
  end

  @doc """
  The text of every element inside `scope` that cuts its own words short:
  an ellipsis, or a box that clips what it holds (wider than it shows).
  `nil` when there is no `scope` on the page.
  """
  @spec cut_off(Playwright.t(), String.t()) :: [String.t()] | nil
  def cut_off(session, scope) do
    run(
      session,
      """
      async (scope) => {
        await document.fonts.ready;
        const roots = [...document.querySelectorAll(scope)];
        if (roots.length === 0) return null;
        const cut = [];
        for (const root of roots) {
          for (const el of [root, ...root.querySelectorAll("*")]) {
            const style = getComputedStyle(el);
            if (style.display === "none" || style.visibility === "hidden") continue;
            const text = el.textContent.replace(/\\s+/g, " ").trim();
            if (text === "") continue;
            const clips = style.overflowX !== "visible" || style.textOverflow === "ellipsis";
            const wide = el.scrollWidth > el.clientWidth + 1;
            const clamped = style.webkitLineClamp !== "none" && el.scrollHeight > el.clientHeight + 1;
            if ((clips && wide) || clamped) cut.push(text);
          }
        }
        return [...new Set(cut)];
      }
      """,
      scope
    )
  end

  @doc """
  How far the words of each element matching `selector` run outside the
  nearest ancestor matching `frame` (and outside the screen), as
  `[%{"text" => text, "by" => px}]`. Empty when every word is inside; `nil`
  when nothing matches `selector`.
  """
  @spec spills(Playwright.t(), String.t(), String.t()) :: [map()] | nil
  def spills(session, selector, frame) do
    run(
      session,
      """
      async ([selector, frame]) => {
        await document.fonts.ready;
        const els = [...document.querySelectorAll(selector)];
        if (els.length === 0) return null;
        const spills = [];
        for (const el of els) {
          const range = document.createRange();
          range.selectNodeContents(el);
          const words = range.getBoundingClientRect();
          const box = (el.closest(frame) || document.documentElement).getBoundingClientRect();
          const by = Math.max(
            box.left - words.left, words.right - box.right,
            box.top - words.top, words.bottom - box.bottom,
            -words.left, words.right - window.innerWidth,
            -words.top, words.bottom - window.innerHeight
          );
          if (by > 1) spills.push({text: el.textContent.trim(), by: Math.round(by)});
        }
        return spills;
      }
      """,
      [selector, frame]
    )
  end

  @doc """
  Whether a text input shows the whole of what it holds: its placeholder
  while it is empty, else its value. Returns `%{"need" => px, "room" => px}`
  (the words' width and the room inside the input's padding), or `nil` when
  there is no such input.
  """
  @spec input_text(Playwright.t(), String.t()) :: map() | nil
  def input_text(session, selector) do
    run(
      session,
      """
      async (selector) => {
        await document.fonts.ready;
        const input = document.querySelector(selector);
        if (!input) return null;
        const empty = input.value === "";
        const style = getComputedStyle(input, empty ? "::placeholder" : null);
        const own = getComputedStyle(input);
        const probe = document.createElement("span");
        for (const prop of ["fontFamily", "fontSize", "fontWeight", "fontStyle", "fontStretch",
                            "letterSpacing", "textTransform", "fontVariationSettings"]) {
          probe.style[prop] = style[prop] || own[prop];
        }
        probe.style.position = "absolute";
        probe.style.visibility = "hidden";
        probe.style.whiteSpace = "pre";
        probe.textContent = empty ? input.placeholder : input.value;
        document.body.appendChild(probe);
        const need = probe.getBoundingClientRect().width;
        probe.remove();
        const room = input.clientWidth - parseFloat(own.paddingLeft) - parseFloat(own.paddingRight);
        return {need: Math.round(need), room: Math.round(room)};
      }
      """,
      selector
    )
  end

  defp run(session, function, arg \\ nil) do
    case Frame.evaluate(session.frame_id,
           expression: function,
           is_function: true,
           arg: arg,
           timeout: timeout()
         ) do
      {:ok, value} -> value
      {:error, error} -> raise "couldn't measure the page: #{inspect(error)}"
    end
  end

  defp timeout, do: Playwright.Config.global(:timeout)
end
