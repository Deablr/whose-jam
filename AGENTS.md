# whose-jam

Jackbox-style song-guessing party game. Phoenix 1.8 + LiveView. Full spec: `docs/prd.md` — read it before implementing anything.

This file is the agent guide for every tool; `CLAUDE.md` is a symlink to it. Edit `AGENTS.md`, never replace the symlink.

## Commands

- `mix precommit` — must pass before any work is considered done. Runs, in the test env: `compile --warnings-as-errors`, `deps.unlock --check-unused`, `format --check-formatted`, `credo`, `sobelow --config`, `docs --warnings-as-errors`, `test`. It only checks; it never rewrites files.
- `mix test <path>` — run a specific test file
- `mix format <files>` — format only the files you changed, never the whole project
- `mix credo <files>` — lint (strict mode is on in `.credo.exs`); `mix credo explain <file>:<line>` explains an issue
- `mix hex.audit` — known security advisories in locked dependencies. Not part of `precommit` (it needs network), so run it after changing dependencies; code review runs it too

Toolchain: Elixir 1.20.2 / OTP 28 via mise (`.tool-versions`). If `mix` prompts to install Hex and hangs, point it at the mise install: `export MIX_HOME=$HOME/.local/share/mise/installs/elixir/1.20.2-otp-28/.mix`.

## Conventions

- Elixir 1.20 / OTP 28, Phoenix 1.8, LiveView 1.2.
- Runtime game state lives in one GenServer per game (`WhoseJam.Game.Server`), registered by room code. Postgres holds only seed content (themes/questions). Never persist runtime game state.
- Pure modules (`Game.Binning`, `Game.Scoring`, `Game.Config`) take plain data in, return plain data out — no processes, no Repo calls, no side effects.
- Tests target external behavior/contracts, not internals. No LiveView tests, no live music-provider API tests, no Registry tests in v1 (manual playtesting per PRD). Provider behavior is covered by the shared contract test (`test/whose_jam/music/provider_contract_test.exs`, one set of expectations run against every enabled provider), the facade's search tests (a stub provider), the OAuth controller's tests (guard rails and an authorize-to-callback flow via a stub redirect provider), and `Game.Server` playing the same game on every provider — never the network. Spotify's response mapping is manual-playtest only.
- HTTP calls use `req` (never `:httpoison`, `:tesla` or `:httpc`). QR codes use `eqrcode` (server-rendered SVG). No other new deps without explicit approval.
- Music-provider credentials come from env vars read at runtime (`System.get_env/1`), never compiled in: `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` (and `SPOTIFY_REDIRECT_URI` override). A provider without credentials reports `configured?/0` false rather than crashing.
- Everything provider-specific lives behind the `WhoseJam.Music.Provider` behaviour (`lib/whose_jam/music/providers/*.ex`, plus a JS player module of the same id in `assets/js/hooks/music/`). `Game.Server`, scoring and the LiveViews must stay provider-neutral — no `if provider == :spotify`. To add a provider: implement the behaviour, add its JS player module and a fixture in `test/support/music_fixtures.ex` (the contract test fails without one), and list it in `config :whose_jam, :music_providers`.

## Shared domain shapes (contracts between modules)

All IDs are strings. These plain-map shapes are the interfaces between independently built modules — do not deviate from them.

- **Player**: `%{id: id, name: String.t(), role: :player | :audience, connected?: boolean()}`
- **Runtime question**: `%{id: id, prompt: String.t(), style: :guess_who | :guess_question}`
- **Vote**: `%{voter_id: id, voter_role: :player | :audience, choice: term()}` — for `:guess_who` the choice is a player id; for `:guess_question` a question id.
- **`Game.Binning.assign(player_ids, questions, questions_per_player, opts \\ [])`** → `%{question_id => [player_id]}`. Guarantees: each player assigned exactly `questions_per_player` questions when feasible, never the same question twice per player, every selected question has ≥ 2 submitters when mathematically feasible. Deterministic under `opts[:seed]`.
- **`Game.Scoring.score_round(round, votes)`** → `%{id => non_neg_integer()}` (point deltas only for scorers). `round` is `%{style: style, submitter_id: id, correct_choice: term()}`. Correct vote: +1 to voter. Submitter: +1 per *incorrect* vote cast by a *non-audience* voter. Audience can earn guess points but never fool-points.
- **`Game.Config`** struct with host-facing fields `answer_timer_s`, `vote_delay_s` (default 10), `vote_timer_s` (countdown, default 30), `questions_per_player`, `subrounds_enabled?`, `allow_vote_change?`, `min_players` (default 3, clamped 2..8; `Game.Config.min_players_range/0`) (plus internal non-overridable constants `song_playback_s`, `reveal_padding_s`, `results_padding_s`). `Game.Config.build(overrides_map, player_count)` → struct (defaults target ~20-min game; only the seven host-facing keys are overridable, and integer overrides are clamped: `answer_timer_s` 1..1800, `vote_delay_s` 0..60, `vote_timer_s` 1..300, `questions_per_player` 1..10, `min_players` 2..8 — exposed via `Game.Config.range(key)`; the derived `questions_per_player` default is clamped too); the 5s all-voted countdown is a `Game.Server` constant, not a config field; `Game.Config.estimated_runtime_s(config, player_count, subround_count \\ 1)` → integer.
- **`WhoseJam.Music.Provider`** (behaviour; modules in `WhoseJam.Music.Providers.*`: `Spotify`, dev/test-only `Mock`): identity (`id/0`, `name/0`, `requirement/0`, `ineligible_message/0`), capabilities (`connect_kind/0` ∈ `:oauth_redirect | :none`, `video?/0`, `configured?/0`), catalog (`search/2`, `valid_uri?/1`, `valid_art_url?/1`), host connection (`connect/1` → `{:ok, auth}`, `authorize_url/2` for redirect providers, `eligible?/1`, optional `refresh/1`), and `client_config/1` (JSON for the browser player). Optional: `playback_error_message/1`. One provider per game, set with `Game.set_music(code, provider_id, auth)`; switching is lobby-only.
- **`WhoseJam.Music`** (facade): `providers/0`, `fetch_provider/1`, `search(provider_id, query, auth)` → `{:ok, [track]} | {:error, term()}` (blank → `{:ok, []}`; the provider is searched with the normalized query and results cached per `{provider, normalized query}`, errors never cached; also `{:error, :unknown_provider}` / `{:error, :not_configured}`), `normalize_track/2`, `playback_error_message/2`, `refresh_if_due/2`, `refresh_delay_ms/1`. LiveViews search through `Game.search_songs(code, query)`.
- **Submitted song** (`Game.submit_song/4`, validated by `Music.Track`): `%{uri, name, artist, album_art_url}` where `uri` is a provider-namespaced string that the *room's* provider's `valid_uri?/1` accepts (Spotify: `spotify:track:<22 alphanumerics>`; another provider's URI is rejected), else the submit returns `{:error, :invalid_song}`; `name`/`artist` are trimmed and capped at 200 codepoints, so ≤ 800 bytes (non-strings → `""`); `album_art_url` is kept only if the provider's `valid_art_url?/1` accepts it (Spotify: `https://i.scdn.co/image/<id>`), else `nil`.
- **PubSub**: topic `"game:" <> code`; the Game.Server broadcasts `{:game_state, view}` where `view` is the public state map returned by `Game.Server.get_state(code)`. LiveViews are pure renderers of that view. The public view carries `music: %{id, name, video?, eligible?} | nil` (never the auth); the host-scoped `Game.host_state(code)` adds `music_auth`.

## Rules from past code reviews

Each of these came up more than once in review. The ones marked *(Credo)* are enforced by a project check in `credo/checks/`; the rest are on you.

- **Never assume success.** Handle `{:error, _}` from `Game.*`, providers and controllers with `with`/`case` — a bare `:ok = ...` or `{:ok, x} = ...` crashes the LiveView (the TV player restarts) or the game process. *(Credo: `NoBareOkMatch`)*
- **Validate every external input at the boundary.** `handle_event` and controller params can be any JSON type or missing: guard string params with `is_binary/1`, and add a fallback clause that flashes or returns 400 rather than raising.
- **Never build a `style` attribute from player or provider data** — HEEx escapes HTML, not CSS, so a crafted album-art URL breaks out of `url(...)`. Use a class, or `<img src={...}>`. The one exception is a helper that only emits server-computed values (like `progress_style/1`): the attribute must be exactly one call to it, and adding a helper to `allowed_helpers` in `.credo.exs` needs the user's approval. *(Credo: `NoDynamicStyle`, which scans `~H` sigils in `.ex` files only — keep dynamic `style` out of standalone `.html.heex` templates by hand.)*
- **One source for limits.** Take ranges from `Game.Config.range/1` and `min_players_range/0`; don't hard-code `2..8`, `1..10` or a player cap in a LiveView.
- **Keep docs in step with the code, in the same change.** When you delete or rename a module, function, callback, config key or behaviour, grep for its name in `lib/` (moduledocs and comments), `test/`, `README.md`, `AGENTS.md`, `REVIEW.md` and `docs/prd.md`. `mix docs --warnings-as-errors` catches stale `Mod.fun/arity` references, but not prose.
- **Tests must be able to fail.** Check that a test fails when the behaviour it names is removed (watch for unit mismatches, e.g. `Phoenix.Token`'s `:signed_at` is in seconds). Test range edges (min, max, max + 1), not only extremes. Drive timers through short test config and `assert_receive` with explicit timeouts. *(Credo: `NoSleepInTests`, `NoGlobalEnvInAsyncTest` — global env changes need `async: false` and an `on_exit` restore.)*
- **Commits and PRs:** imperative subject under ~70 characters; the PR description lists behaviour/config changes and a Testing section of what was actually run (see `REVIEW.md`).

## Hard rules for agents

- Touch only files explicitly assigned to you. `mix.exs`, `config/*`, `lib/whose_jam/application.ex`, `lib/whose_jam_web/router.ex`, `assets/js/app.js`, `.credo.exs`, `credo/checks/*`, `.sobelow-conf` and `.sobelow-skips` are OFF-LIMITS unless your task says otherwise.
- Don't silence a linter to get green. A `# credo:disable-for-next-line` or `# sobelow_skip ["Class"]` needs a comment explaining why the code is safe. Prefer the inline `sobelow_skip` over a `.sobelow-skips` entry (those fingerprints include the line number, so they break when code above them moves); new `.sobelow-skips` entries and any `.sobelow-conf` change need the user's approval.
- Never run `git stash`, `git checkout`, `git switch`, `git branch`, `git commit`, `git push`, `git reset`, or any other git command that mutates state. Read-only git (`git diff`, `git log`, `git status`) is fine.
- Never run `mix format` bare (whole project) — only on your own files.
- Never run `mix ecto.reset`/`drop` — other agents may share the dev database.

---

## Framework guidelines

General Phoenix, Elixir and LiveView guidance from `phx.new`, trimmed to what applies here. Where it conflicts with the project sections above, the project sections win.

### Phoenix v1.8 guidelines

- This app has no auth and no `current_scope`. Its LiveViews (`HomeLive`, `HostLive`, `PlayLive`) render their own full-screen layouts and do not wrap their templates in `<Layouts.app>`; match the surrounding LiveView rather than the generated default
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- This app does use daisyUI: `app.css` loads it as a Tailwind plugin and `core_components.ex` builds on its component classes. Keep using it there; game screens are plain Tailwind plus the `jam-*` classes in `app.css`
- Only the app.js and app.css bundles are supported
  - Don't add external vendor script `src` or link `href` to the layouts. The Google Fonts links in `root.html.heex` are the one existing exception
  - Import vendor deps into app.js and app.css to use them
  - Don't add inline `<script>` tags to templates. The theme script in `root.html.heex` is the one existing exception

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions

### Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

### Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

### Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages

### Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it

### Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/3` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied

### Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>

### Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

#### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

#### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

##### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

##### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

##### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

#### Form handling

##### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

##### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

##### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset

