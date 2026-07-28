# whose-jam

A Jackbox-style song-guessing party game for a room full of friends.

One laptop drives the TV; everyone else plays on their phones. The host picks a
themed pool of prompts like *"The song you'd blast to feel like the main
character walking out of a building"*, and each player answers by searching
Spotify and submitting a track. The TV then plays the songs one at a time
through the host's Spotify Premium account, and after every song the whole room
votes on **who submitted it**. You score for guessing right, and for fooling
other players into voting for your pick. A scoreboard builds between rounds; a
winner is crowned at the end. Default settings aim for a ~20-minute game.

No accounts, no installs for players — they scan a QR code and type a name.

---

## How a game night works

There are three screens, each a Phoenix LiveView keyed by the game's short room
code:

| Screen | URL | Who looks at it |
| --- | --- | --- |
| **TV** | `/tv/:code` | The whole room. Shows the QR code + room code in the lobby, the currently-playing song and album art during rounds, the reveal, and the scoreboard. Also where audio plays. |
| **Host console** | `/host/:code` | The host only. Start game, skip song, settings. |
| **Player** | `/play/:code` | Each phone. Search + submit songs, then vote. |

**The host's setup** is one laptop with two tabs: `/tv/:code` cast to the TV,
and `/host/:code` for the controls. The host also joins `/play/:code` on their
own phone to play along. The TV URL is not tied to any identity — any browser
can open it.

**Host flow:**

1. Open the app, create a game, and pick a theme. Two pools ship with v1:
   *Certified Bangers* (one style: guess-who-submitted-it) and *Emotional
   Damage* (two sub-rounds: guess-who, then guess-which-prompt).
2. Connect a **Spotify Premium** account via OAuth. The game will not start
   without it.
3. Friends scan the QR code on the TV (or type the room code), pick a display
   name, and land in the lobby.
4. Start once at least **3 players** have joined.

**Players vs. audience:** the first 8 joiners are **players** — they get
assigned questions and submit songs. Anyone who joins after that, or after the
game has started, becomes **audience**: they can vote and score for correct
guesses, but they never submit songs and can't win the main board. The lobby
locks when the host hits start.

---

## Quickstart with Docker

This is the recommended path. On a fresh machine you need **only Docker** (with
Compose) — no Elixir, no Postgres.

```sh
# 1. Create your env file
cp .env.example .env

# 2. Generate a signing secret and paste it into .env as SECRET_KEY_BASE
openssl rand -base64 48

# 3. Build and run (Postgres + app)
docker compose up --build

# 4. Open the app
#    http://localhost:4000   (or whatever APP_PORT you set)
```

`SECRET_KEY_BASE` is the only value required to boot. For a **real party**,
also set `PHX_HOST` in `.env` to your laptop's LAN IP (e.g. `192.168.1.23`) so
the QR-code join links and the Spotify OAuth redirect resolve to an address
phones on the same Wi-Fi can actually reach. `localhost` only works when
everything is on the one machine.

Database migrations and the (idempotent) content seeds run automatically on
boot — the compose `command` runs `bin/migrate`, then `bin/seed`, then
`bin/server`, so the two shipped pools are always present. Postgres data
persists in the `pgdata` volume between runs.

To run in the background: `docker compose up --build -d`. To stop:
`docker compose down` (add `-v` to also wipe the database volume).

---

## Spotify setup

Spotify powers both song **search** (app-wide) and TV **playback** (host only).
Without credentials the app boots and the lobby works, but search returns
nothing and no game can play audio.

1. Go to <https://developer.spotify.com/dashboard> and create an app.
2. Add this **redirect URI** to the app, matching your `.env`:

   ```
   http://<PHX_HOST>:<APP_PORT>/auth/spotify/callback
   ```

   For a local run that's `http://localhost:4000/auth/spotify/callback`; for a
   LAN party, `http://192.168.1.23:4000/auth/spotify/callback`.
3. Copy the app's Client ID and Client Secret into `.env`:

   ```sh
   SPOTIFY_CLIENT_ID=your_client_id
   SPOTIFY_CLIENT_SECRET=your_client_secret
   ```

**Two different token flows are in play:**

- **Search** uses the Client Credentials flow — an app-level token, held
  server-side, never shipped to phones. Results are cached in memory per search
  term for a short TTL.
- **Playback** uses the host's OAuth token in the TV browser via the Spotify
  Web Playback SDK. The host completes OAuth during game creation, and the game
  **refuses to start** unless that account is verified as **Premium**.

There is **no free/preview fallback in v1** — a host without Premium cannot
host. Players only see title/artist/art on their phones; audio comes out of the
TV only.

---

## Local development (no Docker)

For hacking on the code without containers.

**Prerequisites:**

- **Elixir 1.20.2 / OTP 28** (the version the release is built against; `mix.exs`
  compiles with `~> 1.17` or newer). A `.tool-versions` file is committed, so
  [mise](https://mise.jdx.dev/) or [asdf](https://asdf-vm.com/) picks the right
  versions up automatically:

  ```sh
  mise install   # or: asdf install
  ```

- A **running Postgres**. `config/dev.exs` expects user `postgres`, password
  `password`, on `localhost:5432`, database `whose_jam_dev`. Adjust
  `config/dev.exs` if your local Postgres differs. (This is distinct from the
  Docker path, which uses user `postgres` / password `postgres` and database
  `whose_jam`.)

**Setup and run:**

```sh
mix setup        # deps.get + ecto.setup (create, migrate, seed) + assets
mix phx.server   # serve on http://localhost:4000
```

`mix setup` runs `mix ecto.setup`, which creates the DB, migrates, and runs
`priv/repo/seeds.exs`. The seeds are **idempotent** (each pool is reseeded by
name), so re-running is safe. To reseed on demand: `mix run priv/repo/seeds.exs`.

The dev server honors the `PORT` env var, e.g. `PORT=4001 mix phx.server`. Note
that dev binds to `127.0.0.1` only — to let phones reach a dev server on your
LAN, change the `ip:` in `config/dev.exs` to `{0, 0, 0, 0}` (the Docker path
already binds all interfaces).

---

## Configuration reference

All configuration is via environment variables (in `.env` for Docker, or your
shell for local dev). Read at runtime by `config/runtime.exs` and wired through
`docker-compose.yml`.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `SECRET_KEY_BASE` | **Yes** | — | Signs/encrypts cookies and session tokens. Generate with `openssl rand -base64 48`. Boot fails (prod/release) if missing. |
| `DATABASE_URL` | **Yes** (prod/Docker) | — | Ecto connection URL, `ecto://USER:PASS@HOST/DB`. Compose sets it to the bundled `db` container automatically. |
| `PHX_HOST` | Recommended | `localhost` | Hostname used in generated URLs (QR join links, OAuth redirect). Set to your LAN IP for a party. |
| `APP_PORT` | No | `4000` | **Compose only.** Host port the app is published on, and the port used in generated URLs (`URL_PORT` defaults to it). |
| `PORT` | No | `4000` | The port the server actually listens on inside the app/container. Used by `mix phx.server` for local dev. |
| `URL_PORT` | No | value of `PORT` | Port embedded in generated URLs. Behind a TLS proxy, set to `443`. Compose sets it to `APP_PORT`. |
| `PHX_SCHEME` | No | `http` | URL scheme for generated links. Set `https` behind a TLS proxy. |
| `POOL_SIZE` | No | `10` | Ecto DB connection pool size (prod). |
| `POSTGRES_PASSWORD` | No | `postgres` | **Compose only.** Password for the bundled Postgres container; also folded into the default `DATABASE_URL`. |
| `SPOTIFY_CLIENT_ID` | For Spotify | — | Spotify app Client ID. Without it, search/playback are disabled. |
| `SPOTIFY_CLIENT_SECRET` | For Spotify | — | Spotify app Client Secret. |

Host-facing **game** settings (answer timer, vote timer, questions per player,
sub-rounds on/off, allow vote-changing) are not env vars — they're chosen per
game in the host console and default to a ~20-minute session.

---

## Architecture at a glance

Phoenix LiveView is the entire web layer; there is no separate frontend.
Everything realtime rides on LiveView + PubSub — no custom WebSocket or
transport code.

- **One GenServer per game** (`WhoseJam.Game.Server`), registered under its room
  code in a `Registry` and supervised by a `DynamicSupervisor`. All runtime
  state — players, assignments, submissions, votes, scores, current phase —
  lives **in memory** in that process and is discarded when the game ends.
  Nothing about a game session is persisted.
- **`WhoseJam.Game`** is the only facade LiveViews call: `create_game`, `join`,
  `start_game`, `submit_song`, `cast_vote`, `skip_song`, etc. — all addressed by
  room code, all returning plain maps or `{:error, reason}`.
- **PubSub fan-out:** the server broadcasts `{:game_state, view}` on topic
  `"game:" <> code`. The TV, host, and every phone subscribe and are pure
  renderers of that view.
- **Postgres holds seed content only** — the two themes and their questions
  (`WhoseJam.Content`). Never runtime game state.
- **Pure modules** carry the game logic and hold the unit tests: `Game.Binning`
  (assign questions to players), `Game.Scoring` (points per round), `Game.Config`
  (derive timings from host overrides + player count). Data in, data out — no
  processes, no Repo, no side effects.
- **`Phoenix.Presence`** tracks who's connected per room; players missing from
  Presence are marked AFK and excluded from "waiting on N players", but their
  submitted songs stay in the game.

```
                        ┌────────────────────────────┐
       broadcasts       │   WhoseJam.Game.Server      │   pure calls
  {:game_state, view}   │   (GenServer, 1 per code)   │  ┌───────────────┐
      ┌─────────────────┤   in-memory runtime state   ├──┤ Binning       │
      │       via       └───────────┬─────────────────┘  │ Scoring       │
      │     PubSub                  │ addressed by        │ Config        │
      │  "game:"<>code              │ room code           └───────────────┘
      ▼                   ┌─────────┴───────────┐
┌───────────┐            │   WhoseJam.Game       │         ┌────────────┐
│ /tv/:code │◄───────────┤   (facade LiveViews   ├────────►│  Postgres  │
│/host/:code│  subscribe │    call)              │  seeds  │  themes /  │
│/play/:code│────────────►                       │◄────────┤ questions  │
└───────────┘  events    └───────────────────────┘         └────────────┘
  LiveViews (pure renderers)                          (Content: seed data only)
```

For the full specification see [`docs/prd.md`](docs/prd.md); for the module
contracts and agent rules see [`CLAUDE.md`](CLAUDE.md).

---

## Testing

```sh
mix test
```

80 tests. In line with the PRD's testing philosophy, coverage is concentrated
where it pays off — the **deep pure modules** and the **GenServer's public API**:

- `Game.Binning` — every player gets their target count, no duplicate
  assignments, each selected question has ≥2 submitters when feasible, edge cases.
- `Game.Scoring` — correct-guess points, submitter fool-points from non-audience
  voters only, all-correct/all-wrong/zero-vote rounds.
- `Game.Config` — derived timings, overrides, default runtime near the 20-minute
  target.
- `Game.Server` — the state machine happy path, rejection of invalid events,
  submission survival across disconnects, vote-timer advance.

`Game.Server` is exercised **through its public event API**, not by peeking at
internal state. Deliberately **manual** (per PRD): LiveViews, the Spotify client,
and the Registry — LiveView tests are brittle, Spotify tests need unstable
external mocks, and the Registry is a thin wrapper. These are validated by
playtesting in v1.

---

## Troubleshooting

**Port 4000 already in use.**
Docker: set a different `APP_PORT` in `.env` (e.g. `APP_PORT=4100`) and reopen on
that port. Local dev: `PORT=4001 mix phx.server`.

**Search returns nothing / a "Spotify not configured" notice.**
`SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` are unset or blank. Add them to
`.env` (Docker: `docker compose up` again to reload) and confirm they came from
your app at developer.spotify.com.

**"Account isn't Premium" and the game won't start.**
This is a hard v1 requirement — the TV plays full tracks via the Web Playback
SDK, which needs Premium. There is no preview/free fallback. Connect a Premium
account.

**Phones can't reach the QR link.**
`PHX_HOST` must be your laptop's **LAN IP**, not `localhost`, and the phones must
be on the **same Wi-Fi**. Update `PHX_HOST` in `.env`, restart, and make sure
your Spotify redirect URI matches the same host and port. (A dev server also
binds loopback-only by default — see Local development.)

**DB connection refused / authentication failed.**
Docker: let the `db` service finish starting (the app waits on its healthcheck);
if you changed `POSTGRES_PASSWORD` after first boot, the old password is baked
into the `pgdata` volume — `docker compose down -v` to reset. Local dev: make
sure Postgres is running and the credentials in `config/dev.exs` (user
`postgres` / password `password` / `localhost:5432`) match your machine.

---

## Project layout

```
whose-jam/
├── config/
│   ├── dev.exs            # local DB creds, dev server, PORT override
│   └── runtime.exs        # env-var config read at boot (prod/release)
├── docs/prd.md            # full product spec — source of truth
├── CLAUDE.md              # module contracts + agent rules
├── docker-compose.yml     # Postgres + app; runs migrate/seed/server on boot
├── Dockerfile             # multi-stage prod release (Elixir 1.20.2 / OTP 28)
├── rel/overlays/bin/      # migrate, seed, server scripts baked into the release
├── priv/repo/
│   ├── migrations/        # schema
│   └── seeds.exs          # the two shipped question pools (idempotent)
├── lib/whose_jam/
│   ├── game.ex            # public facade — the only entrypoint LiveViews use
│   ├── game/
│   │   ├── server.ex      # GenServer: one per game, in-memory runtime state
│   │   ├── binning.ex     # pure: question → players assignment
│   │   ├── scoring.ex     # pure: per-round points
│   │   ├── config.ex      # pure: timings from overrides + player count
│   │   └── codes.ex       # room-code generation
│   ├── content.ex         # seeded themes/questions (Ecto)
│   └── spotify/           # search (client creds) + host OAuth + cache
└── lib/whose_jam_web/
    ├── router.ex          # /, /play/:code, /tv/:code, /host/:code, /auth/spotify*
    ├── live/              # home, play, tv, host LiveViews
    └── presence.ex        # Phoenix.Presence for AFK tracking
```
