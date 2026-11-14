defmodule WhoseJamWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: WhoseJamWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-center z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a status mark: a solid Heroicon in its tone's colour, on nothing
  (`.jam-badge` in `app.css`). Game screens use this instead of emoji, so a
  state is drawn the same way on every device. Its size is its font size;
  keep it small, beside the words it marks.

  ## Examples

      <.jam_badge icon="hero-lock-closed-solid" class="text-xl" />
      <.jam_badge icon="hero-check-circle-solid" tone="mint" class="text-2xl" />
  """
  attr :icon, :string, required: true
  attr :tone, :string, default: "brand", values: ~w(brand mint quiet)
  attr :class, :any, default: nil

  def jam_badge(assigns) do
    ~H"""
    <span
      class={[
        "jam-badge",
        @tone == "mint" && "jam-badge-mint",
        @tone == "quiet" && "jam-badge-quiet",
        @class
      ]}
      aria-hidden="true"
    >
      <.icon name={@icon} class="size-[1em]" />
    </span>
    """
  end

  @doc """
  Renders a player's name written on a strip of tape (`.jam-tape` in
  `app.css`), the one prop a name wears on a game screen. The strip's tilt
  and cut come from the player's id (`tilt_class/1`), so a name looks the
  same on every screen it appears on. Its size is its font size.

  ## Examples

      <.name_tape player_id={p.id} name={p.name} class="text-2xl" />
  """
  attr :player_id, :string, required: true
  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, doc: "anything written on the strip after the name (a mark)"

  def name_tape(assigns) do
    ~H"""
    <span class={["jam-tape", tilt_class(@player_id), @class]} {@rest}>
      <span class="min-w-0 truncate">{@name}</span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  How a player's tape lies and how its strip was cut (`.jam-tilt-0` to
  `.jam-tilt-4` and `.jam-cut-0` to `.jam-cut-4` in `app.css`): the same for
  the same id, on every screen.
  """
  @spec tilt_class(term()) :: String.t()
  def tilt_class(id),
    do: "jam-tilt-#{:erlang.phash2(id, 5)} jam-cut-#{:erlang.phash2({:cut, id}, 5)}"

  @doc """
  A clock's length in seconds as a countdown's numerals show it (`m:ss`), for
  a clock that hasn't started yet: `clock_length(30)` is `"0:30"`.
  """
  @spec clock_length(non_neg_integer()) :: String.t()
  def clock_length(seconds) when is_integer(seconds) and seconds >= 0 do
    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc """
  Where a row sits in its run of equal places in a ranked table (rows as
  `WhoseJam.Game.Standings.rank/2` returns them): `:first`, `:middle` or
  `:last`. A shared place is said once, at the run's first row, and the line
  bracketing the run starts in its first row and ends in its last, so two
  runs that meet never read as one. A row with a place of its own is
  `:first`.
  """
  @spec tie_part([%{id: term(), rank: pos_integer()}], %{id: term(), rank: pos_integer()}) ::
          :first | :middle | :last
  def tie_part(rows, row) do
    run = Enum.filter(rows, &(&1.rank == row.rank))

    cond do
      hd(run).id == row.id -> :first
      List.last(run).id == row.id -> :last
      true -> :middle
    end
  end

  @doc """
  Joins a line of copy's last two words with a no-break space, so a prompt
  that wraps never leaves one word alone on its last line. Copy of three
  words or fewer is left as it is (it may need to break anywhere on a
  narrow screen).
  """
  @spec no_widow(String.t()) :: String.t()
  def no_widow(text) when is_binary(text) do
    if length(String.split(text)) > 3,
      do: String.replace(text, ~r/\s+(\S+)\s*\z/u, "\u00A0\\1"),
      else: text
  end

  @doc """
  Readies a song's title for a poster: a short closing parenthetical ("(if
  i don't mean it)") is kept whole, so a title breaks before it, never
  inside it, and the last line is never one word alone (`no_widow/1`).
  """
  @spec poster_title(String.t()) :: String.t()
  def poster_title(title) when is_binary(title) do
    title =
      Regex.replace(~r/\(([^()]{1,24})\)\s*\z/u, title, fn whole, _inner ->
        String.replace(whole, " ", "\u00A0")
      end)

    no_widow(title)
  end

  def poster_title(other), do: other

  @doc """
  Sets a display headline's curly apostrophes in the body face (`.jam-apos`
  in `app.css`): Lilita One draws its own as an upright tick that stands
  apart from the letters, where the body face's curls into the word. Takes
  plain text; returns it escaped, safe to interpolate.
  """
  @spec curly(String.t()) :: Phoenix.HTML.safe()
  def curly(text) when is_binary(text) do
    parts =
      text
      |> String.split("\u2019")
      |> Enum.map(fn part ->
        part |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      end)
      |> Enum.intersperse(~s(<span class="jam-apos">\u2019</span>))

    {:safe, parts}
  end

  @doc """
  Renders the "now playing" level meter (`.jam-meter` in `app.css`): five
  square bars that move while a song plays. Its size is its font size.
  """
  attr :class, :any, default: nil

  def now_playing_meter(assigns) do
    ~H"""
    <span class={["jam-meter", @class]} role="img" aria-label="Now playing">
      <i></i><i></i><i></i><i></i><i></i>
    </span>
    """
  end

  @doc """
  Renders the game's name as a one-line wordmark in its own lettering, for a
  screen's header: the speech-bubble logo is for the front door, and shrunk
  to a header it stops reading. Its size is its font size.
  """
  attr :class, :any, default: nil

  def wordmark(assigns) do
    ~H"""
    <span
      class={["whitespace-nowrap font-display leading-none text-jam-cream", @class]}
      role="img"
      aria-label="Whose Jam"
    >
      <span aria-hidden="true">Whose <span class="text-jam-pink">Jam</span></span>
    </span>
    """
  end

  @doc """
  Renders a stroke of pink marker (`.jam-stroke` in `app.css`), drawn by hand
  in the same hand as the names, and only where it says something: a ring
  round the name a player locked in (`:circle`), a line under the revealed
  name (`:underline`), the winner's crown (`:crown`), and the arrow that
  points a player to their own name (`:arrow`). It takes its colour from the
  text colour and its size from its box; `.jam-stroke-draw` draws it in.
  """
  attr :kind, :atom, required: true, values: [:circle, :underline, :crown, :arrow]
  attr :class, :any, default: nil

  def marker_stroke(assigns) do
    assigns = assign(assigns, :shape, stroke_shape(assigns.kind))

    ~H"""
    <svg
      class={["jam-stroke", @class]}
      viewBox={@shape.box}
      preserveAspectRatio={@shape.aspect}
      fill="none"
      aria-hidden="true"
    >
      <path :for={d <- @shape.paths} d={d} vector-effect="non-scaling-stroke" />
    </svg>
    """
  end

  # A loop that overshoots where it started, as a ring drawn in one go does.
  defp stroke_shape(:circle),
    do: %{
      box: "0 0 200 100",
      aspect: "none",
      paths: [
        "M116 11C163 8 195 25 192 52C189 80 143 94 97 91C49 89 8 76 9 49C10 23 49 8 98 8C131 7 159 13 181 26"
      ]
    }

  # A quick line and a shorter one back under it.
  defp stroke_shape(:underline),
    do: %{
      box: "0 0 200 24",
      aspect: "none",
      paths: ["M4 12C52 6 118 4 196 8", "M40 19C86 15 132 14 172 16"]
    }

  defp stroke_shape(:crown),
    do: %{
      box: "0 0 64 46",
      aspect: "xMidYMid meet",
      paths: [
        "M9 40C8 31 6 21 5 12L19 26L32 5L45 26L59 12C58 21 56 31 55 40C40 42 24 42 9 40Z"
      ]
    }

  # From the word to the name on its left, curving up into it.
  defp stroke_shape(:arrow),
    do: %{
      box: "0 0 40 24",
      aspect: "xMidYMid meet",
      paths: ["M37 18C27 21 14 18 5 9", "M5 9L14 8", "M5 9L7 18"]
    }

  @doc """
  Renders an open modal dialog. Render it conditionally with `:if`; Escape and
  a backdrop click both push the `on_close` event. The box is a
  `role="dialog"` / `aria-modal` element wrapped in `<.focus_wrap>`, so Tab
  stays inside it, and focus moves into it when it opens.

  ## Examples

      <.modal :if={@open?} id="settings-modal" on_close="close" class="max-w-lg" body_class="space-y-6">
        ...
      </.modal>
  """
  attr :id, :string, required: true, doc: "DOM id for the dialog (required by focus_wrap)"
  attr :on_close, :string, required: true, doc: "the event pushed on Escape or backdrop click"
  attr :class, :any, default: nil, doc: "extra classes for the modal box (e.g. `max-w-*`)"

  attr :body_class, :any,
    default: nil,
    doc:
      "classes for the inner wrapper around the content; put `space-y-*` here, since " <>
        "focus_wrap's tab sentinels break sibling spacing on the box itself"

  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      class="modal modal-open bg-jam-ink/[0.96] backdrop-blur-[24px]"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <.focus_wrap
        id={@id}
        role="dialog"
        aria-modal="true"
        phx-mounted={JS.focus_first(to: "#" <> @id)}
        class={["modal-box", @class]}
      >
        <div class={@body_class}>
          {render_slot(@inner_block)}
        </div>
      </.focus_wrap>
      <div class="modal-backdrop" phx-click={@on_close}></div>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(WhoseJamWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(WhoseJamWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
