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

There are two screens, each a Phoenix LiveView keyed by the game's short room
code:

| Screen | URL | Who looks at it |
| --- | --- | --- |
| **Host screen** | `/host/:code` (also `/tv/:code`) | The whole room, on the TV. Shows the QR code + room code in the lobby, the currently-playing song and album art during rounds, the reveal, and the scoreboard. Also where audio plays. A slim top bar carries the host controls: music-service status, skip song, and a Settings panel (music service + game settings). |
| **Player** | `/play/:code` | Each phone. Search + submit songs, then vote. |

**The host's setup** is one laptop showing `/host/:code` on the TV. If no music
service is connected, the lobby prompts the host to connect one (Spotify today;
the picker is built to list more services later). The host also joins
`/play/:code` on their own phone to play along. The host URL is not tied to any
identity — any browser can open it.

**Host flow:**

1. Open the app, create a game, and pick a theme. Two pools ship with v1:
   *Certified Bangers* (one style: guess-who-submitted-it) and *Emotional
   Damage* (two sub-rounds: guess-who, then guess-which-prompt).
2. Connect a **Spotify Premium** account via OAuth. The game will not start
   without it.
3. Friends scan the QR code on the TV (or type the room code), pick a display
   name, and land in the lobby.
4. Start once at least **3 players** have joined (the host can lower this to
   2 in Settings → "Players needed to start", handy for development).

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
the QR-code join links resolve to an address phones on the same Wi-Fi can
actually reach — `localhost` only works when everything is on the one machine.
(The Spotify OAuth redirect is separate and stays on `127.0.0.1`; see
[Spotify setup](#spotify-setup).)

Database migrations and the (idempotent) content seeds run automatically on
boot — the compose `command` runs `bin/migrate`, then `bin/seed`, then
`bin/server`, so the two shipped pools are always present. Postgres data
persists in the `pgdata` volume between runs.

To run in the background: `docker compose up --build -d`. To stop:
`docker compose down` (add `-v` to also wipe the database volume).

Port publishing lives in `docker-compose.override.yml`, which Compose merges
automatically for local runs. The base `docker-compose.yml` publishes **no
ports** — that's deliberate, for reverse-proxy deployments (below).

### Deploying with Dokploy (Traefik)

The base compose file is proxy-ready: Traefik reaches the `app` service on the
Docker network at port `4000`, and no host ports are published (platforms that
pass an explicit compose file skip the local override). In Dokploy:

1. Create a Compose service from this repo (`docker-compose.yml`).
2. Point a domain at service `app`, container port `4000` (Dokploy writes the
   Traefik routing; enable HTTPS there).
3. Set the environment variables:

   ```sh
   SECRET_KEY_BASE=<openssl rand -base64 48>
   PHX_HOST=your.domain.com        # bare hostname — no scheme, no trailing slash
   PHX_SCHEME=https
   SPOTIFY_CLIENT_ID=...
   SPOTIFY_CLIENT_SECRET=...
   SPOTIFY_REDIRECT_URI=https://your.domain.com/auth/spotify/callback
   POSTGRES_PASSWORD=<something strong>
   ```

   `SPOTIFY_REDIRECT_URI` must be set explicitly here (and registered in the
   Spotify dashboard): the loopback default only makes sense when the server
   runs on the host's own laptop. With HTTPS, Spotify accepts the real domain.

---

## Music providers

Everything music-service-specific sits behind the `WhoseJam.Music.Provider`
behaviour (see `CLAUDE.md` for the contract and how to add one). Spotify is the
only provider that ships. In **dev and test** a fake **Mock Music** provider is
also enabled (`config :whose_jam, :music_providers`): a handful of made-up
tracks, no credentials and no audio — each song just "ends" after a few
seconds — so you can play a whole game locally without a Spotify account.
Pick it in the lobby's music-service list.

## Spotify setup

Spotify powers both song **search** (app-wide) and TV **playback** (host only).
Without credentials the app boots and the lobby works, but search returns
nothing and no game can play audio.

1. Go to <https://developer.spotify.com/dashboard> and create an app. When the
   form asks *which API/SDKs are you planning to use*, select **Web API** and
   **Web Playback SDK** — nothing else (no Android, iOS, or Ads API).
2. Add this **redirect URI** to the app (match your `APP_PORT` — the port is
   part of the exact match):

   ```
   http://127.0.0.1:4000/auth/spotify/callback
   ```

   Spotify **rejects `localhost`** and any non-HTTPS URI that isn't a loopback
   IP (`127.0.0.1` / `[::1]`), so the app always sends a `127.0.0.1` redirect —
   even at a LAN party where phones join via your LAN IP. That works because
   the OAuth round-trip happens in the host's browser on the same machine that
   runs the server; don't register a LAN-IP redirect URI, Spotify won't accept
   it. Deploying behind TLS instead? Register your https URI and set
   `SPOTIFY_REDIRECT_URI=https://your.domain/auth/spotify/callback`.
3. Copy the app's Client ID and Client Secret into `.env`:

   ```sh
   SPOTIFY_CLIENT_ID=your_client_id
   SPOTIFY_CLIENT_SECRET=your_client_secret
   ```

**Exactly what the app uses:**

| Spotify product | Where | Calls |
| --- | --- | --- |
| **Web API** | Server (Client Credentials token) | `GET /v1/search` — song search from phones, proxied server-side |
| **Web API** | Server (host's OAuth token) | `GET /v1/me` — Premium verification after OAuth |
| **Web API** | TV browser (host's OAuth token) | `PUT /v1/me/player/play` — start each round's track on the TV device |
| **Web Playback SDK** | TV browser | Turns the host screen into a Spotify Connect device; reports track end |
| Accounts service | Server | OAuth authorize/token endpoints (Authorization Code + Client Credentials flows) |

The Android SDK, iOS SDK, and Ads API are **not** used.

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
| `PHX_HOST` | Recommended | `localhost` | Hostname used in generated URLs (QR join links). Set to your LAN IP for a party. Not used for the Spotify redirect. |
| `SPOTIFY_REDIRECT_URI` | No | `http://127.0.0.1:<url port>/auth/spotify/callback` | OAuth redirect sent to Spotify; must exactly match a URI registered in your Spotify app. Override only for https deployments. |
| `APP_PORT` | No | `4000` | **Local compose only** (`docker-compose.override.yml`). Host port the app is published on, and the port used in generated URLs. Not used by proxy deployments. |
| `PORT` | No | `4000` | The port the server actually listens on inside the app/container. Used by `mix phx.server` for local dev. |
| `URL_PORT` | No | `443` when `PHX_SCHEME=https`, else value of `PORT` | Port embedded in generated URLs. Only needed for a non-standard public port. The local override sets it to `APP_PORT`. |
| `PHX_SCHEME` | No | `http` | URL scheme for generated links. Set `https` behind a TLS proxy (Dokploy). |
| `POOL_SIZE` | No | `10` | Ecto DB connection pool size (prod). |
| `POSTGRES_PASSWORD` | No | `postgres` | **Compose only.** Password for the bundled Postgres container; also folded into the default `DATABASE_URL`. |
| `SPOTIFY_CLIENT_ID` | For Spotify | — | Spotify app Client ID. Without it, search/playback are disabled. |
| `SPOTIFY_CLIENT_SECRET` | For Spotify | — | Spotify app Client Secret. |

Host-facing **game** settings (answer timer, listening delay before voting,
vote countdown, questions per player, sub-rounds on/off, allow vote-changing,
players needed to start) are not env vars — they're chosen per game in the host
screen's Settings panel and default to a ~20-minute session.

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
  `"game:" <> code`. The host screen (which is
  also the TV display) and every phone subscribe and are pure renderers of that
  view.
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
│/host/:code│◄───────────┤   (facade LiveViews   ├────────►│  Postgres  │
│           │  subscribe │    call)              │  seeds  │  themes /  │
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

In line with the PRD's testing philosophy, coverage is concentrated
where it pays off — the **deep pure modules** and the **GenServer's public API**:

- `Game.Binning` — every player gets their target count, no duplicate
  assignments, each selected question has ≥2 submitters when feasible, edge cases.
- `Game.Scoring` — correct-guess points, submitter fool-points from non-audience
  voters only, all-correct/all-wrong/zero-vote rounds.
- `Game.Config` — derived timings, overrides, default runtime near the 20-minute
  target.
- `Game.Server` — the state machine happy path, rejection of invalid events,
  submission survival across disconnects, vote-timer advance, and the same game
  played on every music provider.
- Music providers — one shared contract test run against every enabled
  provider, the facade's search caching, and the OAuth controller's signed-state
  guard rails.

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
be on the **same Wi-Fi**. Update `PHX_HOST` in `.env` and restart. The Spotify
redirect URI is unaffected — it stays on `127.0.0.1`. (A dev server also binds
loopback-only by default — see Local development.)

**Playback banner on the host screen shows `EMEError: No supported keysystem`.**
The Web Playback SDK plays DRM-protected audio via EME/Widevine, and the TV
browser can't. Fixes: use **Chrome, Edge, or Firefox** for the host screen; allow
protected content (Chrome: `chrome://settings/content/protectedContent`; Brave:
enable Widevine in `brave://settings/extensions`); and open the TV over
**https** or on the serving machine via `localhost`/`127.0.0.1` — plain http on
a LAN IP is an insecure context where browsers disable DRM entirely. Search and
everything else work regardless; only playback needs DRM.

**Spotify says "invalid redirect URI" (or the dashboard rejects the URI).**
Spotify doesn't accept `localhost` or plain-http non-loopback hosts. Register
exactly `http://127.0.0.1:<APP_PORT>/auth/spotify/callback` (port included) and
start the OAuth flow from the machine running the server. Behind TLS, register
your https URI and set `SPOTIFY_REDIRECT_URI` to the same value.

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
│   ├── music.ex           # provider-neutral facade: search + cache, song validation, token upkeep
│   ├── music/             # Provider behaviour, cache, providers/{spotify,mock}.ex
│   └── spotify/           # Spotify HTTP client + OAuth helpers (used by the Spotify provider)
└── lib/whose_jam_web/
    ├── router.ex          # /, /play/:code, /host/:code (+ /tv alias), /auth/:provider*
    ├── live/              # home, play, host LiveViews
    └── presence.ex        # Phoenix.Presence for AFK tracking
```
