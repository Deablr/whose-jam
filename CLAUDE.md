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
- Tests target external behavior/contracts, not internals. No LiveView tests, no Spotify API tests, no Registry tests in v1 (manual playtesting per PRD).
- HTTP calls use `req`. QR codes use `eqrcode` (server-rendered SVG). No other new deps without explicit approval.
- Spotify credentials come from env vars `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` read at runtime (`System.get_env/1`), never compiled in.

## Shared domain shapes (contracts between modules)

All IDs are strings. These plain-map shapes are the interfaces between independently built modules — do not deviate from them.

- **Player**: `%{id: id, name: String.t(), role: :player | :audience, connected?: boolean()}`
- **Runtime question**: `%{id: id, prompt: String.t(), style: :guess_who | :guess_question}`
- **Vote**: `%{voter_id: id, voter_role: :player | :audience, choice: term()}` — for `:guess_who` the choice is a player id; for `:guess_question` a question id.
- **`Game.Binning.assign(player_ids, questions, questions_per_player, opts \\ [])`** → `%{question_id => [player_id]}`. Guarantees: each player assigned exactly `questions_per_player` questions when feasible, never the same question twice per player, every selected question has ≥ 2 submitters when mathematically feasible. Deterministic under `opts[:seed]`.
- **`Game.Scoring.score_round(round, votes)`** → `%{id => non_neg_integer()}` (point deltas only for scorers). `round` is `%{style: style, submitter_id: id, correct_choice: term()}`. Correct vote: +1 to voter. Submitter: +1 per *incorrect* vote cast by a *non-audience* voter. Audience can earn guess points but never fool-points.
- **`Game.Config`** struct with host-facing fields `answer_timer_s`, `vote_delay_s` (default 10), `vote_timer_s` (countdown, default 30), `questions_per_player`, `subrounds_enabled?`, `allow_vote_change?`, `min_players` (default 3, clamped 2..8; `Game.Config.min_players_range/0`) (plus internal non-overridable constants `song_playback_s`, `reveal_padding_s`, `results_padding_s`). `Game.Config.build(overrides_map, player_count)` → struct (defaults target ~20-min game; only the seven host-facing keys are overridable, and integer overrides are clamped: `answer_timer_s` 1..1800, `vote_delay_s` 0..60, `vote_timer_s` 1..300, `questions_per_player` 1..10, `min_players` 2..8 — exposed via `Game.Config.range(key)`; the derived `questions_per_player` default is clamped too); the 5s all-voted countdown is a `Game.Server` constant, not a config field; `Game.Config.estimated_runtime_s(config, player_count, subround_count \\ 1)` → integer.
- **`WhoseJam.Spotify.search(query)`** → `{:ok, [%{uri, name, artist, album_art_url}]} | {:error, term()}`.
- **Submitted song** (`Game.submit_song/4`): `uri` must match `spotify:track:<22 alphanumerics>` or the submit returns `{:error, :invalid_song}`; `name`/`artist` are trimmed and capped at 200 codepoints, so ≤ 800 bytes (non-strings → `""`); `album_art_url` is kept only if it is an `https://i.scdn.co/image/<id>` URL, else `nil`.
- **PubSub**: topic `"game:" <> code`; the Game.Server broadcasts `{:game_state, view}` where `view` is the public state map returned by `Game.Server.get_state(code)`. LiveViews are pure renderers of that view.

## Hard rules for agents

- Touch only files explicitly assigned to you. `mix.exs`, `config/*`, `lib/whose_jam/application.ex`, `lib/whose_jam_web/router.ex`, and `assets/js/app.js` are OFF-LIMITS unless your task says otherwise.
- Never run `git stash`, `git checkout`, `git switch`, `git branch`, `git commit`, `git push`, `git reset`, or any other git command that mutates state. Read-only git (`git diff`, `git log`, `git status`) is fine.
- Never run `mix format` bare (whole project) — only on your own files.
- Never run `mix ecto.reset`/`drop` — other agents may share the dev database.
