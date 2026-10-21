## Problem Statement

When friends gather for a party, music is a natural way to express personality and prompt conversation, but there isn't a good shared-screen group game built around songs the way Jackbox is built around prompts and drawings. The user (the game host) wants a party game they can run on a TV in ~20 minutes with 3–8 of their friends, where the *content* of the game is songs their friends actually choose in response to evocative prompts, and the *fun* of the game is guessing which friend chose what.

## Solution

A web-based, Jackbox-style party game where:

- The host opens a URL on a laptop connected to a TV, which displays a QR code and room code.
- 3–8 players join from their phones by scanning the QR code and entering a display name. Additional joiners become audience members who can vote but do not submit songs.
- The host picks a themed question pool (e.g., "Emotional Damage," "The Club"). Each theme is a curated pool of prompts like "Song that changed your life" or "Grooves to flirt to."
- Every player is assigned a small set of questions drawn from the pool. They don't see each other's questions, and the same question may be assigned to multiple players.
- Each player searches Spotify on their phone and submits a song for each assigned question.
- Once answers are in, the host's TV plays submitted songs one at a time using Spotify's Web Playback SDK (requires host Premium). After each song, all connected clients (players + audience) vote to guess which player submitted it.
- Players score +1 per correct guess and +1 per non-audience vote they fooled onto their own song. Audience members score +1 per correct guess but are not submitters and do not win the main board.
- At the end, a final scoreboard appears on the TV.

Question pools can bundle multiple question *styles*. v1 ships one fully playable style (guess-who-submitted-this) and demonstrates the architecture with a second style (guess-the-question) as a POC. When a pool contains multiple styles, the game breaks into sub-rounds — one sub-round per style — cycling through answer-then-play for each. Hosts can disable sub-rounds to flatten a multi-style game into a single answer-then-play cycle.

## User Stories

### Host — creating and running a game

1. As a host, I want to open a single URL on my laptop and create a new game with one click, so that I can get a party started quickly without signing up for anything.
2. As a host, I want to see a QR code and a short alphanumeric room code on the TV, so that friends can join either by scanning or typing.
3. As a host, I want to connect a music service (Spotify Premium via OAuth in v1) before the game begins — and be prompted to connect one if I open the lobby without it — so that the TV can play full songs during rounds.
4. As a host, I want to be told clearly and early if Spotify Premium is missing, so that I'm not blindsided mid-game.
5. As a host, I want to pick a themed question pool from a short list, so that I can tune the vibe (e.g., wholesome vs. rowdy) to my friend group.
6. As a host, I want to preview two or three example questions per pool (drawn from questions that won't be used in the actual game), so that I know what style of prompts to expect without spoiling the session.
7. As a host, I want to open a settings panel to adjust default settings (answer timer, vote timer, questions per player, sub-rounds on/off) and manage my music-service connection, so that I can make the game shorter, longer, or structured differently for my group without settings cluttering the TV.
8. As a host, I want the default settings to produce a ~20-minute game, so that I can run it without fiddling.
9. As a host, I want to see on the TV a live roster of who has joined as players vs. audience, so that I know when to start.
10. As a host, I want to start the game only when at least three players have joined, so that the guessing mechanic is non-trivial.
11. As a host, I want to skip a song mid-round (with a confirmation), so that a broken link or regrettable pick doesn't ruin the vibe.
12. As a host, I want to join my own game as a player from my phone, so that I can participate.

### Player — joining

13. As a player, I want to join a game by scanning a QR code with my phone, so that I don't have to type a URL.
14. As a player, I want to join a game by typing a short room code, so that I can still join if my camera is fussy.
15. As a player, I want to pick a display name with no account creation required, so that I can start playing within seconds.
16. As a player, I want my device to remember the game I joined, so that if I refresh or lock my phone I can rejoin without losing my spot.
17. As a player, I want to know if I've joined as a player or as audience, so that I'm not surprised when I don't get a form.

### Player — submitting songs

18. As a player, I want to see my assigned questions one at a time on my phone, so that I can focus on one submission at a time.
19. As a player, I want to search Spotify directly from the submission form, so that I can find songs without leaving the app.
20. As a player, I want the search results to show song title, artist, and album art, so that I can confirm I'm picking the right version.
21. As a player, I want to see a live countdown for the submission phase, so that I know how much time I have.
22. As a player, I want to change my song pick before the submission timer ends, so that I can second-guess myself.
23. As a player, I want to be told if the submission timer expires before I finish, so that I understand why my unfinished questions won't be in the game.

### Voting

24. As a voter (player or audience), I want to see the currently-playing song's title, artist, and art on my phone, so that I have context for my guess.
25. As a voter, I want to pick from the list of *players* (not audience members) when guessing who submitted, so that the choices are scoped correctly.
26. As a voter for a guess-the-question round, I want to pick from a list of candidate questions instead of players, so that the alternative style works.
27. As a voter, I want a visible countdown for voting, so that I know how long I have.
28. As a voter, I want my vote locked in once submitted (no changes), so that the game keeps moving — unless the host has enabled vote-changing in the settings.
29. As a voter, I want to see on the TV that my vote was received, so that I know I'm not holding things up.

### TV screen

30. As a host, I want the TV screen to always show the current game state clearly, so that people looking up from their phones can follow along.
31. As a host, I want the TV to display the room code and QR code during the lobby, so that latecomers can still join.
32. As a host, I want the TV to display the currently-playing song's title, artist, and album art during rounds, so that everyone has shared context.
33. As a host, I want the TV to reveal the correct submitter after each vote, with a brief moment for reactions, so that the room can laugh at surprising picks.
34. As a host, I want the TV to show the running scoreboard between rounds, so that tension builds through the game.
35. As a host, I want the TV to show a final scoreboard at the end, so that there's a clear winner.
36. As a host, I want the TV to separate player and audience scores visually, so that the "official" winner is always a submitter.

### Disconnection and reconnection

37. As a player, I want to reconnect automatically if my phone briefly loses signal, so that I don't have to rejoin manually.
38. As a host, I want the game to not stall on a disconnected player, so that one bad phone doesn't ruin the evening.
39. As a host, I want disconnected players' already-submitted songs to stay in the game, so that their contributions aren't wasted.
40. As a player, I want to silently drop into whatever is happening now if I reconnect mid-game, so that I don't replay old rounds I missed.

### Content and themes

41. As a host, I want to choose between at least two themed pools in v1 (one single-style, one multi-style), so that I can see the breadth of the game.
42. As a host, I want the multi-style pool to group questions into sub-rounds by style, so that the flow alternates between answering and playing multiple times per game.

## Implementation Decisions

### Stack

- **Phoenix + LiveView** for the entire web layer. Chosen because the per-game-room model maps cleanly onto OTP processes, PubSub handles the TV-and-phones fan-out for free, and Phoenix Presence solves liveness tracking.
- **Ecto + Postgres** for seed data (themes, questions, pools) only. Runtime game state lives in memory in a GenServer per game.
- **Phoenix.Token** for device→player binding; the token is stored in a cookie and is sufficient to identify a returning device.
- **No authentication system in v1.** No Better Auth, no user accounts. Hosts don't register. Players don't register. The only auth involved is the host's OAuth flow to Spotify.

### Runtime architecture

- Each active game is one `Game.Server` GenServer, registered under a short room code in a Phoenix Registry.
- State transitions flow through explicit events (`:join`, `:start`, `:submit_song`, `:cast_vote`, `:skip_song`). The GenServer publishes game-state broadcasts via Phoenix.PubSub on a per-room topic.
- All LiveViews (host screen, player) subscribe to the room topic; they are pure renderers of state received from the GenServer.
- `Phoenix.Presence` tracks connected clients per room. Players absent from Presence for a short threshold are marked AFK and excluded from "waiting on N players" counts, but their existing submissions stay live.
- When a game ends (final scoreboard shown + short idle timeout), the GenServer shuts down and its state is discarded.

### Data model

- **Static (Ecto-managed, seeded at compile/deploy time):**
  - `themes` — id, name, description, style_sequence (ordered list of styles that defines the sub-round structure of the theme).
  - `questions` — id, theme_id, prompt text, style (enum: `:guess_who`, `:guess_question`, `:guess_for_player` reserved for future), is_example (flagged questions used only in host previews and excluded from gameplay selection).
- **Runtime (in-memory only, not persisted):** players, audience, assignments, submissions, votes, scores, current phase. Lost when the game ends.

### Game flow and state machine

- States: `:lobby` → (repeating per sub-round) `:answering` → `:playing` (with per-round sub-states `:revealing`, `:voting`, `:results`) → `:finished`.
- A sub-round corresponds to one style from the theme's `style_sequence`. When the host disables sub-rounds, the sequence collapses into a single `:answering` phase that covers all styles before any `:playing`.
- Answer timer is global per sub-round (computed from questions assigned). Vote timer runs per round (default 30s, configurable).
- When the vote timer expires or all non-AFK voters have voted, the round advances. Voters who don't vote earn no points that round.
- The host can skip songs via a button in the host screen's control bar. No pause feature in v1.
- After `:finished`, the TV offers a "Start a new game with these players" option, which resets state but preserves the player roster.

### Question styles (v1)

- **`:guess_who` (primary)** — a player submits a song for a prompt; voters select which player submitted it. Fully implemented.
- **`:guess_question` (POC)** — a player submits a song for a prompt; voters select which prompt the song was submitted for, from a list of candidates drawn from the pool. Minimally implemented to demonstrate the multi-style architecture; present in one of the two shipped pools.
- **`:guess_for_player` (reserved)** — enum value present in the schema but no runtime implementation in v1.
- Styles are dispatched via pattern matching in round-handling code; no rules engine.

### Question pools (v1)

- Two pools shipped with v1:
  - A **single-style pool** consisting entirely of `:guess_who` questions (one sub-round).
  - A **multi-style pool** combining `:guess_who` and `:guess_question` questions (two sub-rounds when sub-rounds are enabled).
- Pools are seeded from source-controlled data; content written by the product owner. No user-generated questions in v1.
- Each pool includes a small set of `is_example: true` questions shown as previews to hosts, so sample questions shown in the lobby never overlap with the actual game.

### Player assignment (binning)

- `Game.Binning` is responsible for assigning questions to players within a sub-round. Input: player count, question pool for the style, questions-per-player target. Output: a map of question → player list.
- The exact algorithm is not specified in this PRD — any approach that produces a valid assignment (every player gets their target count, no duplicate assignments per player, every selected question has at least 2 submitters when feasible) is acceptable. This choice is left to the implementer.
- The module is pure: given the same inputs, it returns the same assignment (modulo a seeded shuffle for determinism in tests).

### Scoring

- `Game.Scoring` is a pure module called after each round. For the round's song:
  - Voters who selected the correct submitter: +1.
  - The submitter: +1 for each vote from a *non-audience* player they fooled onto their song.
  - Audience members: can gain points from correct guesses but can never be the submitter; their scoring path is one-sided.
- Scores are stored in the GenServer state and displayed on the TV between rounds and at the end.

### Timing and configuration

- `Game.Config` computes concrete timings from host overrides plus player count. Defaults aim for ~20-minute games.
- Every timing and volume parameter exposed to the host is configurable: answer timer, vote timer, questions per player, whether sub-rounds are enabled, whether vote-changing is allowed.
- When player counts or question counts exceed what fits in the target window, the game will exceed 20 minutes; there is no hard cap on round count in v1.

### Spotify integration

- **Search:** server-side, using Spotify client credentials (app-level token, not host-linked). Results cached in-memory per search term for a short TTL to reduce API calls. Key is held server-side; never shipped to players.
- **Playback:** Spotify Web Playback SDK on the host screen's browser only. Host completes OAuth from the lobby (connect prompt or Settings); the game refuses to start if the host is not authenticated and Premium-verified.
- **Music services are pluggable in the UX.** The host picks from a list of music services; Spotify is the only entry in v1, shown alongside a "more services coming soon" placeholder. Host-facing copy says "music service" rather than assuming Spotify, so adding a provider later is a new list entry rather than a UI redesign. (Search and playback internals remain Spotify-specific in v1.)
- **Only the host plays audio.** Players may see album art and song title on their phones during rounds but do not play audio. No per-player preview audio in v1.
- Submitted songs are stored by Spotify track URI.

### Players, audience, and capacity

- 3 to 8 submitters per game. Attempting to join a ninth player promotes the joiner to audience.
- Audience has no hard cap in v1 but a soft limit (~20) with a friendly message if exceeded.
- Audience members cannot be promoted to players mid-game.
- Lobby locks when the host starts the game; late joiners become audience regardless of player count.

### Device and session handling

- Players are identified by a signed Phoenix.Token cookie binding their device to `{game_id, player_id, role}`, with a TTL matching typical game duration.
- On page load, if the cookie matches an active game, the player is restored silently.
- If a player disconnects mid-answering, any songs they'd already submitted remain in the game; unsubmitted questions are left blank. They can reconnect and continue where they left off if Presence hasn't timed them out.
- If a player disconnects mid-voting, their missed votes are forfeited; reconnection drops them into whatever the current round is.

### Host screen architecture

- The TV display and host controls are **one screen** at `/host/:code` (`/tv/:code` is kept as an alias). It is not bound to host identity; any browser can open it. The host's typical setup is a laptop showing `/host/:code` on the TV, plus `/play/:code` on their own phone as a player.
- The screen renders the shared game state big and dark for the room. Host controls live in a slim top bar: music-service status (prompts to connect when none is connected), skip song (during rounds), and a Settings button.
- Settings open on demand as a panel with two sections: **Music service** (connect / reconnect / switch account) and **Game** (the five host-facing settings plus the estimated runtime; locked once the game starts).
- In the lobby, if no premium-ready music service is connected, a "Connect your music" prompt opens automatically (dismissible), and the Start button explains what's missing. Playback failures (e.g. a browser without DRM support) are shown in the lobby, before the game starts.

### Explicitly out of the way

- No WebSockets work beyond what LiveView already provides.
- No custom transport layer. PubSub + LiveView channels handle all realtime.
- No Redis or external queue. One BEAM node is enough for v1.

## Testing Decisions

### Testing philosophy

- Tests target *external behavior* of a module, not its internal structure. A test should still pass after a full internal refactor as long as the module's contract is preserved.
- Deep, pure modules are prioritized for unit tests because they offer the highest test-value-per-line-of-test.
- The GenServer is tested through its public event API, not by peeking at internal state. Tests send events and observe the resulting public state (via the same query functions LiveViews will use).
- LiveViews, Spotify integration, and the Registry are validated by manual playtesting in v1 rather than by automated tests — LiveView tests are brittle, Spotify tests require mocking external APIs that are unstable for v1, and the Registry is a thin wrapper around Phoenix.Registry.

### Modules with tests

- **`Game.Binning`** — correctness of assignment (every player gets their target; no player gets the same question twice), overlap guarantee (every selected question has ≥2 submitters whenever mathematically feasible), edge cases (minimum player count, more questions requested than exist).
- **`Game.Scoring`** — a correct guess awards +1; a submitter gains +1 per fooled non-audience vote; audience cannot be "fooled onto" for scoring purposes; all-correct and all-wrong rounds produce sane totals; a round with zero votes produces zero points.
- **`Game.Config`** — derived timings at representative player counts; overrides override; default settings produce a game whose total estimated runtime is within a configured band of the 20-minute target.
- **`Game.Server`** — state machine happy path (lobby → answering → playing → finished); invalid events in the wrong state are rejected without crashing; disconnection during answering preserves prior submissions; vote-timer expiry advances the round even with missing votes.

### Prior art

- This is a greenfield project with no existing codebase. The testing patterns will be set by this PRD's implementation and should be treated as the prior art for later features.

## Out of Scope

- **Authentication and user accounts.** No Better Auth, no host accounts, no player accounts.
- **Persistent game state.** Games evaporate when they end; no playlist saving, no game history, no replay.
- **User-generated questions.** All content is author-curated and baked into seeds.
- **Question-idea submission by players.** Deferred until there's a real user base to collect ideas from.
- **Mid-game changes.** No late joiners becoming players, no audience promotion, no pause.
- **Vote changing.** Votes are locked once submitted (a host toggle for this is conceptually supported but not prioritized for v1).
- **Avatars, images, and custom player art.** Display name only.
- **Video playback.** Audio via Spotify Web Playback SDK only. No YouTube, no music videos. A simple visualizer or album-art display is the intended TV visual during rounds.
- **Full implementation of `:guess_for_player` style.** Enum reserved; no runtime logic.
- **Rich question-style engine.** Dispatch is via pattern matching on an enum. No DSL, no rules engine.
- **Spotify-free playback fallback.** If the host lacks Premium, v1 does not offer 30-second previews or a YouTube fallback. They cannot host.
- **Tests for LiveViews, Spotify client, and the Registry.** Manual playtesting only in v1.
- **Multi-node deployment, Redis, external queues.** Single-node BEAM is the deployment model.
- **Mobile apps.** Mobile web only.

## Further Notes

- The game is optimized for a specific social setting: 3–8 friends in the same room, one TV, laptop host, everyone on their phones. Decisions like "require Spotify Premium" and "audience doesn't score overall" were made in service of that setting and may be revisited when the product is used in other contexts.
- Sub-rounds are the main structural lever distinguishing this game from a flat Jackbox-style "submit everything, then play everything" loop. The decision to default to sub-rounds (rather than making them a hidden advanced feature) is deliberate: they keep the answer phase from becoming a homework assignment.
- The BEAM's process-per-game model is a deliberate bet on Phoenix specifically. If this were a React/Node stack, the equivalent would be Durable Objects or a sticky-session GenServer shim, and the complexity budget would be meaningfully larger.
- v2 candidates, in rough priority order: playlist persistence and sharing, the `:guess_for_player` style, user-generated question submissions with a moderation flow, the `:guess_question` style expanded to a first-class citizen with better pool coverage, Spotify-free playback fallback, and optional host accounts for saving preferred settings and themes.
- The 20-minute target is a soft guideline. Hosts who crank up questions-per-player will get longer games; that's fine. The default configuration is where the product's quality bar lives.
