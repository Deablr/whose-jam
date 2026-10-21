# whose-jam

Jackbox-style song-guessing party game. Phoenix 1.8 + LiveView. Full spec: `docs/prd.md` — read it before implementing anything.

## Commands

- `mix compile --warnings-as-errors` — must pass before any work is considered done
- `mix test <path>` — run a specific test file
- `mix format <files>` — format only the files you changed, never the whole project

## Conventions

- Elixir 1.20 / OTP 28, Phoenix 1.8, LiveView 1.1.
- Runtime game state lives in one GenServer per game (`WhoseJam.Game.Server`), registered by room code. Postgres holds only seed content (themes/questions). Never persist runtime game state.
- Pure modules (`Game.Binning`, `Game.Scoring`, `Game.Config`) take plain data in, return plain data out — no processes, no Repo calls, no side effects.
- Tests target external behavior/contracts, not internals. No LiveView tests, no live music-provider API tests, no Registry tests in v1 (manual playtesting per PRD). Provider behavior is covered by the shared contract test (`test/whose_jam/music/provider_contract_test.exs`, one set of expectations run against every enabled provider), the facade's search tests (a stub provider), the OAuth controller's tests (guard rails and an authorize-to-callback flow via a stub redirect provider), and `Game.Server` playing the same game on every provider — never the network. Spotify's response mapping is manual-playtest only.
- HTTP calls use `req`. QR codes use `eqrcode` (server-rendered SVG). No other new deps without explicit approval.
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

## Hard rules for agents

- Touch only files explicitly assigned to you. `mix.exs`, `config/*`, `lib/whose_jam/application.ex`, `lib/whose_jam_web/router.ex`, and `assets/js/app.js` are OFF-LIMITS unless your task says otherwise.
- Never run `git stash`, `git checkout`, `git switch`, `git branch`, `git commit`, `git push`, `git reset`, or any other git command that mutates state. Read-only git (`git diff`, `git log`, `git status`) is fine.
- Never run `mix format` bare (whole project) — only on your own files.
- Never run `mix ecto.reset`/`drop` — other agents may share the dev database.
