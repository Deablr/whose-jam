## Problem Statement

When friends gather for a party, music is a natural way to express personality and prompt conversation, but there isn't a good shared-screen group game built around songs the way Jackbox is built around prompts and drawings. The user (the game host) wants a party game they can run on a TV in ~20 minutes with 3–8 of their friends, where the *content* of the game is songs their friends actually choose in response to evocative prompts, and the *fun* of the game is guessing which friend chose what.

## Solution

A web-based, Jackbox-style party game where:

- The host opens a URL on a laptop connected to a TV, which displays a QR code and room code.
- 3–8 players join from their phones by scanning the QR code and entering a display name. Additional joiners become audience members who can vote but do not submit songs.
- The host picks a themed question pool (e.g., "Emotional Damage," "The Club"). Each theme is a curated pool of prompts like "Song that changed your life" or "Grooves to flirt to."
- Every player is assigned a small set of questions drawn from the pool. They don't see each other's questions, and the same question may be assigned to multiple players.
- Each player searches the room's music service (Spotify or YouTube) on their phone and submits a song for each assigned question.
- Once answers are in, the host's TV plays submitted songs one at a time through the music provider's web player (Spotify's Web Playback SDK, which requires host Premium, or YouTube's IFrame player). While each song plays, all connected clients (players + audience) vote to guess which player submitted it.
- Players score +1 per correct guess and +1 per non-audience vote they fooled onto their own song. When their own song plays they don't guess whose it is: they make a *prediction* (whom the fooled players will blame: the wrong answer most players give), for +1 more if they are right. The TV's reveal says how the prediction went, right or not, and the picker's phone uses the same words, true however few were fooled (one word for the mechanic, blame: "+1 Predicted Dev, and called it" ("… Dev & Gus …" for a tie; "+1 for predicting Dev" on the picker's phone), or, as clearly but with no points to it, "Predicted Fern, but Gus took the blame" or "Predicted Fern, but nobody was fooled"; whoever most of the wrong guesses went to "took the blame", never "the room"; "called it" is kept for the right guessers); the picker's phone gives the fooling points and the prediction a line each, so the points add up; the end-of-game recap gives the player's score and where it came from (9 points, then 5 correct guesses, 3 players fooled and 1 prediction right, each a number over its words). Audience members score +1 per correct guess but are not submitters and do not win the main board.
- At the end, a final scoreboard appears on the TV.

Question pools can bundle multiple question *styles*. v1 ships one fully playable style (guess-who-submitted-this) and demonstrates the architecture with a second style (guess-the-question) as a POC. When a pool contains multiple styles, the game breaks into sub-rounds — one sub-round per style — cycling through answer-then-play for each. Hosts can disable sub-rounds to flatten a multi-style game into a single answer-then-play cycle.

## User Stories

### Host — creating and running a game

1. As a host, I want to open a single URL on my laptop and create a new game with one click, so that I can get a party started quickly without signing up for anything.
2. As a host, I want to see a QR code and a short alphanumeric room code on the TV, so that friends can join either by scanning or typing.
3. As a host, I want to connect a music service (Spotify Premium via OAuth, or YouTube via Google sign-in) before the game begins — and be prompted to connect one if I open the lobby without it — so that the TV can play full songs during rounds.
4. As a host, I want to be told clearly and early if Spotify Premium is missing — or, on YouTube, warned that ads may play without YouTube Premium — so that I'm not blindsided mid-game.
5. As a host, I want to pick a themed question pool from a short list, so that I can tune the vibe (e.g., wholesome vs. rowdy) to my friend group.
6. As a host, I want to preview two or three example questions per pool (drawn from questions that won't be used in the actual game), so that I know what style of prompts to expect without spoiling the session.
7. As a host, I want to open a settings panel to adjust default settings (answer timer, listening delay, vote countdown, questions per player, sub-rounds on/off) and manage my music-service connection, so that I can make the game shorter, longer, or structured differently for my group without settings cluttering the TV.
8. As a host, I want the default settings to produce a ~20-minute game, so that I can run it without fiddling.
9. As a host, I want to see on the TV a live roster of who has joined as players vs. audience, so that I know when to start.
10. As a host, I want to start the game only when at least three players have joined, so that the guessing mechanic is non-trivial — with a "players needed to start" setting I can lower to two for development or very small groups.
11. As a host, I want to skip a song mid-round (with a confirmation), so that a broken link or regrettable pick doesn't ruin the vibe.
12. As a host, I want to join my own game as a player from my phone, so that I can participate.
13. As a host, I want an "Exit game" button on the final scoreboard, so that I can close the room and everyone's phones know the game is over.
14. As a host, I want the game to end for everyone when I close the host screen (after a short grace for a refresh or a dropped connection, and never just because I'm signing in to a music service), so that players aren't left waiting on a game nobody is running.

### Player — joining

15. As a player, I want to join a game by scanning a QR code with my phone, so that I don't have to type a URL.
16. As a player, I want to join a game by typing a short room code, so that I can still join if my camera is fussy. Someone arriving after the game has started (or when every seat is taken) is told before they enter a name that they'll join the audience, and the button says so. A code with no game behind it says so and offers the code box again, so a typo is fixed where it happened.
17. As a player, I want to pick a display name with no account creation required, so that I can start playing within seconds.
18. As a player, I want my device to remember the game I joined, so that if I refresh or lock my phone I can rejoin without losing my spot. A phone that ends up on the home page while its game is on is offered "Back to your game (CODE)" above the join form.
19. As a player, I want to know if I've joined as a player or as audience, so that I'm not surprised when I don't get a form.

### Player — submitting songs

20. As a player, I want to see my assigned questions one at a time on my phone, so that I can focus on one submission at a time.
21. As a player, I want to search the music service directly from the submission form, so that I can find songs without leaving the app.
22. As a player, I want the search results to show song title, artist, and album art, so that I can confirm I'm picking the right version.
23. As a player, I want to see a live countdown for the submission phase, so that I know how much time I have.
24. As a player, I want to change my song pick before the submission timer ends, so that I can second-guess myself.
25. As a player, I want to be told if the submission timer expires before I finish, so that I understand why my unfinished questions won't be in the game.

### Voting

26. As a voter (player or audience), I want to see the currently-playing song's title, artist, and art on my phone, so that I have context for my guess.
27. As a voter in a guess-who round, I want to see the prompt the song was picked for on the TV and on my phone, so that I know what the question was.
28. As a voter, I want to pick from the list of *players* (not audience members) when guessing who submitted, so that the choices are scoped correctly.
29. As a voter for a guess-the-question round, I want to pick from a list of candidate questions instead of players, so that the alternative style works.
30. As a voter, I want a visible countdown for voting, so that I know how long I have.
31. As a voter, I want my vote locked in once submitted (no changes), so that the game keeps moving — unless the host has enabled vote-changing in the settings. Submitting takes two taps, a name and then "Lock in", so a stray thumb costs nothing; with vote-changing on, one tap votes and another changes it.
31a. As the player whose song is playing, I want my phone to keep everyone else's layout while the vote is open, so that nothing on it moves or changes shape to give me away, and to ask me my own question, so that I know what to do. It has everyone's layout: the same "Listen up", the headline in the same place, the same names, lock-in button and locked-in card. The words are mine: while the song plays it says "Your song. Keep a straight face." where others read "It's playing on the TV."; the headline asks "Who'll get the blame?" ("Which prompt takes the blame?" in a prompt round) where others read "Whose jam is this?", with "Predict the most popular wrong guess. +1 if you call it." under it (where others read "Pick who you think chose it. +1 if you’re right."); and once I lock in, my card says "Your prediction" where others say "Locked in". That guess is kept apart from the votes (it never counts as one) and is worth a point if most of the fooled players name that one. Every player is also told how this works once, on their own phone, while they wait for the others to pick songs.
32. As a voter, I want my phone to say back what I picked, and the TV to show who is in, so that I know my vote landed and whether the room is waiting on me. The TV shows a chip for each player that fills in as they lock in (audience members get a labelled row of their own), and a count ("5 of 9 in"). In the last five seconds the clock turns amber on the TV and on every phone, and a vote that closes on the clock is revealed with "Time's up. It was…". The submitter is one of the names (their own guess counts as being in, and the round waits for it like any vote), so the list gives nobody away; what anyone chose is never shown before the reveal.

### TV screen

33. As a host, I want the TV screen to always show the current game state clearly, so that people looking up from their phones can follow along.
34. As a host, I want the TV to display the room code and QR code during the lobby, so that latecomers can still join.
35. As a host, I want the TV to display the currently-playing song's title, artist, and album art during rounds, so that everyone has shared context. The song is shown as a poster: its cover printed on a sheet of egg-white paper with its title and artist set in ink, once, a touch askew. While the room listens and votes it is a wide sheet with the title large beside the cover, readable from the sofa; at the reveal it steps back to a small print with the title under the cover. Each phone shows the same poster while the song plays. (A video provider's player can't be printed, so it shows the title and artist beside the player.)
36. As a host, I want the TV to reveal the correct submitter after each vote, with a brief moment for reactions, so that the room can laugh at surprising picks. The reveal is built top-down in three beats on the TV, always in the same places: "It was…" holds the room for about a second, then the submitter's name lands alone (or "Time's up. It was…" when the clock closed the vote); about a second later what the round was worth to the picker, each line led by its points ("+5 Fooled 5 of 7", or "Everyone saw through it.", or "Nobody fell for it." when somebody didn't vote, or "No player fell for it." when only the audience did, as an audience guess never scores for the picker; "+1 Predicted Ben, and called it", or "Predicted Dev, but Fern took the blame" (or "…, but nobody was fooled")); and a second after that a card for each player who was named, with who named them (the right one headed "N called it"), and a dimmed one for anyone who let the clock run out ("1 didn't vote"), with the points landing in the score strip. (The host's "Quick reveals" setting lands it all within about a second.) Each phone keeps its locked-in screen (what its player said, or "Time ran out before you voted."), the bar at its foot now saying "Eyes on the TV", until that has played out, then says what the round meant for its own player ("You called it", "Eli got you: you said Fern", "You fooled Cleo and Dev").
37. As a host, I want the TV to show the running scoreboard between rounds, so that tension builds through the game. The scores run along the bottom of the TV for the whole playing phase, and each phone carries its own player's score. No score changes before the submitter's name is on screen: one that moved first would give the answer away. Every player keeps one seat in the strip all game (the order they joined), so a name is always where the room last saw it; each seat shows its score and whether it leads (places are the final board's to give; a strip of tied "1st"s says nothing from across the room). At a reveal each seat that changed gives way, in place, to its new score (guess points in mint, the picker's bluff points in orange, as the lobby's rule line colours them); nothing moves across the screen, and the leader's seat is outlined all game. A phone that has dropped out dims its seat and tags it "away". The game's last reveal doesn't settle the table: each seat shows only what it won that round (nothing for a round that won nothing), a label on the strip says "This round · final scores next", and the phones hold their totals, so the winner is the final board's news. That board fills from the bottom, one place at a time (equal places together), up to second, then holds first place empty for a moment; then the winner's name has the screen to itself, about twice a reveal's size and under the poster of their song (captioned when it was the night's best bluff), held for about four seconds while the room reacts, before a quick crossfade to the full table with them on top. A tie is announced once, as the winners land, and the audience's scores arrive after them. The finished screen is tinted from that cover, as a round is from its song's.
38. As a host, I want the TV to show a final scoreboard at the end, so that there's a clear winner. Players on the same score share a place (8, 8, 7 is 1st, 1st, 3rd) on the TV and on every phone; no screen presents the order of two tied players as a result. The ending is one screen: the winner and the awards on one side, the whole table in one column on the other. The table fills from the bottom (everyone below third at once, then third, then second, then a held breath under "And the winner is…") and the winner lands last, in first place and the headline at once (with how close it was; a tie is headed "It's a tie"); then come up to two awards that say what the game is remembered for (the best bluff: the song that fooled the most players; the sharpest ears: whoever called the most songs). An award more than two players share singles nobody out, and one worth a single point (fooling one player, calling one song) is no feat, so neither is shown. The host can switch the board for the night's playlist, with who picked each song. Phones wait for the TV to name the winner, then lead with their own player's result, a line on how their game went, and any award that player holds.
39. As a host, I want the TV to separate player and audience scores visually, so that the "official" winner is always a submitter.

### Disconnection and reconnection

40. As a player, I want to reconnect automatically if my phone briefly loses signal, so that I don't have to rejoin manually.
41. As a host, I want the game to not stall on a disconnected player, so that one bad phone doesn't ruin the evening.
42. As a host, I want disconnected players' already-submitted songs to stay in the game, so that their contributions aren't wasted.
43. As a player, I want to silently drop into whatever is happening now if I reconnect mid-game, so that I don't replay old rounds I missed.

### Content and themes

44. As a host, I want to choose between at least two themed pools in v1 (one single-style, one multi-style), so that I can see the breadth of the game.
45. As a host, I want the multi-style pool to group questions into sub-rounds by style, so that the flow alternates between answering and playing multiple times per game.

## Implementation Decisions

### Stack

- **Phoenix + LiveView** for the entire web layer. Chosen because the per-game-room model maps cleanly onto OTP processes, PubSub handles the TV-and-phones fan-out for free, and Phoenix Presence solves liveness tracking.
- **Ecto + Postgres** for seed data (themes, questions, pools) only. Runtime game state lives in memory in a GenServer per game.
- **Phoenix.Token** for device→player binding; the token is stored in a cookie and is sufficient to identify a returning device.
- **No authentication system in v1.** No Better Auth, no user accounts. Hosts don't register. Players don't register. The only auth involved is the host connecting a music service (Spotify's OAuth flow, or a Google sign-in for YouTube).

### Runtime architecture

- Each active game is one `Game.Server` GenServer, registered under a short room code in a Phoenix Registry.
- State transitions flow through explicit events (`:join`, `:start`, `:submit_song`, `:cast_vote`, `:skip_song`). The GenServer publishes game-state broadcasts via Phoenix.PubSub on a per-room topic.
- Submitted songs are validated server-side against the room's music provider: the URI must be a well-formed song URI of that provider (for Spotify, `spotify:track:<22 alphanumerics>`; a URI from any other provider is rejected too) or the submission is rejected; name/artist are trimmed and capped at 200 characters; album art is kept only if it is hosted where that provider's art lives (for Spotify, its image CDN).
- All LiveViews (host screen, player) subscribe to the room topic; they are pure renderers of state received from the GenServer.
- `Phoenix.Presence` tracks connected clients per room. Players absent from Presence for a short threshold are marked AFK and excluded from "waiting on N players" counts, but their existing submissions stay live.
- A game ends when the host exits it from the final scoreboard, when no host screen has been open for 30 seconds (each open host screen is monitored by the GenServer; a host screen that left for a music service's sign-in page gets 15 minutes, so connecting one never ends the game), or after a short idle timeout (an abandoned lobby, or a final scoreboard left up). Every screen is told: phones say the game is over (a finished game keeps its final scores on screen); a host screen whose host exited from the final scoreboard stays on a closing card ("Thanks for playing", who took it, and "Host another game"), and any other host screen returns to the start page. Then the GenServer shuts down and its state is discarded.

### Data model

- **Static (Ecto-managed, seeded at compile/deploy time):**
  - `themes` — id, name, description, style_sequence (ordered list of styles that defines the sub-round structure of the theme).
  - `questions` — id, theme_id, prompt text, style (enum: `:guess_who`, `:guess_question`, `:guess_for_player` reserved for future), is_example (flagged questions used only in host previews and excluded from gameplay selection).
- **Runtime (in-memory only, not persisted):** players, audience, assignments, submissions, votes, scores, current phase. Lost when the game ends.

### Game flow and state machine

- States: `:lobby` → (repeating per sub-round) `:answering` → `:playing` (with per-round sub-states `:revealing`, `:voting`, `:results`) → `:finished`.
- A sub-round corresponds to one style from the theme's `style_sequence`. When the host disables sub-rounds, the sequence collapses into a single `:answering` phase that covers all styles before any `:playing`.
- Answer timer is global per sub-round (computed from questions assigned). Once every connected player has picked all their songs the phase ends early, after a 1.5s pause: the room sees the last player lock in ("Everyone's in") before the first song starts.
- Each round's song starts playing with votes closed for a listening delay (default 10s, configurable). Voting then opens while the song keeps playing, with no countdown yet.
- The vote countdown (default 30s, configurable) starts once a majority of eligible (connected, non-submitter) voters have voted — or when the song ends, so a round can never stall. Once every eligible voter has voted, the countdown drops to 3s (never lengthening a shorter one). When it hits zero the round moves to the reveal. Voters who don't vote earn no points that round.
- The host can skip songs via a button in the host screen's control bar. No pause feature in v1.
- After `:finished`, the TV offers a "Play again" option, which resets state but preserves the player roster (and seats anyone who watched from the audience in any free player seats, in the order they joined), and an "Exit game" button, which ends the game for everyone.

### Question styles (v1)

- **`:guess_who` (primary)** — a player submits a song for a prompt; voters select which player submitted it. The TV and phones show the prompt throughout the round, so the room knows what the question was (binning gives each prompt at least two submitters when feasible, so the prompt alone doesn't give the submitter away). Fully implemented.
- **`:guess_question` (POC)** — a player submits a song for a prompt; voters select which prompt the song was submitted for, from a list of candidates drawn from the pool. Minimally implemented to demonstrate the multi-style architecture; present in one of the two shipped pools.
- **`:guess_for_player` (reserved)** — enum value present in the schema but no runtime implementation in v1.
- Styles are dispatched via pattern matching in round-handling code; no rules engine.

### Question pools (v1)

- Two pools shipped with v1:
  - A **single-style pool** consisting entirely of `:guess_who` questions (one sub-round).
  - A **multi-style pool** combining `:guess_who` and `:guess_question` questions (two sub-rounds when sub-rounds are enabled: guess-the-prompt first, then guess-who).
- Pools are seeded from source-controlled data; content written by the product owner. No user-generated questions in v1.
- Each pool includes a small set of `is_example: true` questions shown as previews to hosts, so sample questions shown in the lobby never overlap with the actual game.

### Player assignment (binning)

- `Game.Binning` is responsible for assigning questions to players within a sub-round. Input: player count, question pool for the style, questions-per-player target. Output: a map of question → player list.
- The exact algorithm is not specified in this PRD — any approach that produces a valid assignment (every player gets their target count, no duplicate assignments per player, every selected question has at least 2 submitters when feasible) is acceptable. This choice is left to the implementer.
- The module is pure: given the same inputs, it returns the same assignment (modulo a seeded shuffle for determinism in tests).

### Scoring

- `Game.Scoring` is a pure module called after each round. For the round's song:
  - Voters who selected the correct submitter: +1.
  - The submitter: +1 for each vote from a *non-audience* player they fooled onto their song, and +1 more if their own forecast (which wrong answer the room would fall for) names the wrong answer most players gave, alone or tied for most.
  - Audience members: can gain points from correct guesses but can never be the submitter; their scoring path is one-sided.
- Scores are stored in the GenServer state and displayed on the TV between rounds and at the end.

### Timing and configuration

- `Game.Config` computes concrete timings from host overrides plus player count. Defaults aim for ~20-minute games.
- Every timing and volume parameter exposed to the host is configurable: answer timer, listening delay before voting, vote countdown, questions per player, whether sub-rounds are enabled, whether vote-changing is allowed, and the minimum players needed to start (default 3, range 2–8). The server clamps every numeric setting to a safe range (answer timer 1–1800s, listening delay 0–60s, vote countdown 1–300s, questions per player 1–10, minimum players 2–8) so no value can stall or crash a game.
- When player counts or question counts exceed what fits in the target window, the game will exceed 20 minutes; there is no hard cap on round count in v1.

### Music providers

The game is bound to one music provider per room, chosen by the host in the lobby. Everything provider-specific sits behind the `WhoseJam.Music.Provider` behaviour; the game runtime, scoring and screens only ever see the provider-neutral song `%{uri, name, artist, album_art_url}`. Providers differ in eight places: identity and host-facing copy, catalog search and song validation (including how long the player screen waits before searching as you type), how the host connects, whether the account is eligible, token refresh, the browser player (a JS module of the same id), capabilities (`configured?`, `video?`), and what the server can't verify about the account (a yes/no question for the host, and a non-blocking warning).

Enabled providers come from `config :whose_jam, :music_providers`. Spotify and YouTube ship; dev and test also enable the fake **Mock** provider.

**Spotify**

- **Search:** server-side, using Spotify client credentials (app-level token, not host-linked). Results cached in-memory per search term for a short TTL to reduce API calls. Key is held server-side; never shipped to players.
- **Playback:** Spotify Web Playback SDK on the host screen's browser only. Host completes OAuth from the lobby (connect prompt or Settings); the game refuses to start if the host is not authenticated and Premium-verified.
- **Music services are pluggable in the UX.** The host picks from a list of music services, each with its own mark; one the server has no credentials for says so ("Not set up on this server"). Host-facing copy says "music service" rather than assuming Spotify, so adding a provider is a new list entry rather than a UI redesign.

**YouTube**

- **Search:** server-side, YouTube Data API v3 with an API key; embeddable music videos only. Google allows a Cloud project roughly 100 searches a day, so YouTube rooms search 600 ms after the last keystroke (Spotify: 300 ms; the server enforces the same spacing per connection, and only joined players — not audience — can search, while songs are being picked), results are cached like Spotify's, and a used-up quota is reported to players as such.
- **Sign-in:** the host signs in with Google (OAuth, `openid` scope only; no tokens and no account identity are kept, since the host screen is shown to the whole room). Choosing YouTube without being signed in sends the host to Google's sign-in. A signed-in account is all the game needs to start.
- **Premium:** Google has no API or scope that reports YouTube Premium, so it cannot be verified. After sign-in the lobby asks the host whether the account has it. Unless the answer is yes, the lobby and Settings show a warning that ads may play before or during songs; the game still starts. The answer can be changed in Settings.
- **Playback:** the IFrame player on the host screen, visible where the album art would be while a song plays (YouTube's terms require a visible, unobscured player). It runs with the host browser's own YouTube session, so ads can still appear for a Premium account if the browser blocks third-party cookies. YouTube refuses to play in a page opened by IP address (`127.0.0.1`, a LAN IP), so over plain http the Google sign-in returns the host to `localhost` (over https, to the app's own domain), and the host screen says so if it is opened by IP.

**Mock** (dev/test only)

A small fixed catalog, no credentials, no connect step. Most tracks are fake and play no audio: the browser stub reports each song as ended after a few seconds. Six are real songs from NoCopyrightSounds (credited in `priv/static/audio/mock/CREDITS.txt`), played for real at their real length when their audio files have been copied in (they are kept out of git; `mix test.e2e` copies them from a local folder), and like the fake ones otherwise. Each track has a placeholder cover served by the app itself (`/images/mock/<id>.svg`), so the screens look as they do with a real service's artwork. It lets a whole game be played and tested without a Spotify account.

**Researched and shelved**

A throwaway proof of concept for Apple Music (a provider authorized inside the browser, via MusicKit's sign-in popup) was built to prove the `Provider` behaviour fits that shape, then removed. (YouTube was shelved the same way at first — for its search quota, ads and the visible-player rule — and later shipped with those limits surfaced to the host, as described above.) Apple Music is not offered to hosts, because:

- **Apple Music:** a MusicKit developer token needs a MusicKit key, which needs a paid Apple Developer Program membership (Account Holder or Admin role). If this is ever revived, sign the ES256 developer token with `jose`.

What the proofs of concept needed beyond Spotify: a `video?` capability (kept, and used by YouTube — the host screen then shows the player), a browser-authorized connect kind (removed again as unused; a provider like Apple Music would need a third `connect_kind` plus a hook to run the sign-in in the host's browser), and a per-provider search-cache scope for storefront-dependent results (also removed as unused).

- Submitted songs are stored by provider-namespaced song URI (`spotify:track:…`, `youtube:video:…`).

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

- The TV display and host controls are **one screen** at `/host/:code` (`/tv/:code` is kept as an alias). It is not bound to host identity; any browser can open it, and the game lasts while at least one is open. The host's typical setup is a laptop showing `/host/:code` on the TV, plus `/play/:code` on their own phone as a player.
- The screen renders the shared game state big and dark for the room. Host controls live in a slim top bar: music-service status (prompts to connect when none is connected), skip song (during rounds), and a Settings button.
- Settings open on demand as a panel with three sections: **Music service** (connect / reconnect / switch account), **Game** (the host-facing settings — including players needed to start — plus the estimated runtime; locked once the game starts) and **On the screens**, four choices about how the screens tell the game (never the scoring or the timers), for rooms that like it another way: *Quick reveals* (each reveal lands nearly at once and the winner is held briefly, instead of in staged beats; off by default), *Name who didn't vote* (on; off counts them without naming anyone), *Show every place on the score strip* (off; by default only the leader is marked) and *Hide totals during the final round* (on, keeping them for the final scores; off shows the last round's totals as they land).
- In the lobby, if no music service that can play is connected (Spotify with Premium, or YouTube signed in), a "Connect your music" prompt opens automatically (dismissible), and the Start button explains what's missing. Playback failures (e.g. a browser without DRM support) are shown in the lobby, before the game starts.

### Explicitly out of the way

- No WebSockets work beyond what LiveView already provides.
- No custom transport layer. PubSub + LiveView channels handle all realtime.
- No Redis or external queue. One BEAM node is enough for v1.

## Testing Decisions

### Testing philosophy

- Tests target *external behavior* of a module, not its internal structure. A test should still pass after a full internal refactor as long as the module's contract is preserved.
- Deep, pure modules are prioritized for unit tests because they offer the highest test-value-per-line-of-test.
- The GenServer is tested through its public event API, not by peeking at internal state. Tests send events and observe the resulting public state (via the same query functions LiveViews will use).
- `Phoenix.LiveViewTest` tests, live provider API (Spotify, Google/YouTube) tests and Registry tests are out of scope in v1 — LiveView unit tests are brittle, provider tests require mocking external APIs that are unstable for v1, and the Registry is a thin wrapper around Phoenix.Registry. LiveViews are instead exercised end to end: a browser suite plays a whole game (host plus 8 players across phones, tablets and laptops) against the real server and a containerized Postgres, faking only the music provider, and records a combined video. What *is* tested is the provider abstraction itself: one shared contract test runs against every enabled provider (URI/art validation, cross-provider rejection, eligibility, JSON-safe client config), the facade's search caching/normalization is tested with a stub provider, the OAuth controller is tested without any provider API (signed-state guard rails, and the authorize-to-callback flow via a stub redirect provider, including that leaving to sign in doesn't end the game), and `Game.Server` plays the same game on every provider. Spotify's response mapping is manual-playtest only.

### Modules with tests

- **`Game.Binning`** — correctness of assignment (every player gets their target; no player gets the same question twice), overlap guarantee (every selected question has ≥2 submitters whenever mathematically feasible), edge cases (minimum player count, more questions requested than exist).
- **`Game.Scoring`** — a correct guess awards +1; a submitter gains +1 per fooled non-audience vote, and +1 for a forecast that names the wrong answer most players gave (ties count; audience votes don't; the correct answer or one nobody gave earns nothing); audience cannot be "fooled onto" for scoring purposes; all-correct and all-wrong rounds produce sane totals; a round with zero votes produces zero points.
- **`Game.Config`** — derived timings at representative player counts; overrides override; default settings produce a game whose total estimated runtime is within a configured band of the 20-minute target.
- **`Game.Server`** — state machine happy path (lobby → answering → playing → finished); invalid events in the wrong state are rejected without crashing; disconnection during answering preserves prior submissions; disconnection during voting can complete a majority / everyone-voted; vote-timer expiry advances the round even with missing votes; submitted album-art URLs other than the room provider's art host are dropped; songs from another provider are rejected; guess-who rounds show their prompt and guess-question rounds keep it hidden until the reveal; the game ends, telling every screen, when the host ends it, when its last host screen stays closed past the grace (not when one comes back in time, and not while the host is signing in to a music service, which only a host screen can start: one still open, as it is when the host clicks Connect (a plain link, so the page stays connected until the provider's page loads), or, within the grace, one whose connection dropped just before the click), and when a lobby is abandoned or a finished game sits idle.
- **Browser end-to-end** (`mix test.e2e`, tagged `:e2e`, not part of `mix test`) — a host and 8 players on phones, tablets and laptops play a whole game; the final scoreboard is checked against an independently computed tally, and the host's Exit game button tells every phone the game is over.

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
- **Video for audio-only providers.** Spotify is audio-only: no music videos, and album art is the TV visual during rounds. Video appears only where the provider's own player is a video player — YouTube, through the `video?` capability (the host screen then shows the player in place of the album art); see "Music providers".
- **Full implementation of `:guess_for_player` style.** Enum reserved; no runtime logic.
- **Rich question-style engine.** Dispatch is via pattern matching on an enum. No DSL, no rules engine.
- **Automatic playback fallback.** A host without Spotify Premium cannot host with Spotify; there are no 30-second previews and no automatic switch to another service. They can pick YouTube instead in the lobby. A previews-only provider was considered and explicitly rejected.
- **Tests for LiveViews (`Phoenix.LiveViewTest`), the providers' HTTP calls (Spotify, Google/YouTube), and the Registry.** LiveViews are covered only by the browser end-to-end suite; the provider APIs are manual playtesting only in v1.
- **Multi-node deployment, Redis, external queues.** Single-node BEAM is the deployment model.
- **Mobile apps.** Mobile web only.

## Further Notes

- The game is optimized for a specific social setting: 3–8 friends in the same room, one TV, laptop host, everyone on their phones. Decisions like "require Spotify Premium" and "audience doesn't score overall" were made in service of that setting and may be revisited when the product is used in other contexts.
- Sub-rounds are the main structural lever distinguishing this game from a flat Jackbox-style "submit everything, then play everything" loop. The decision to default to sub-rounds (rather than making them a hidden advanced feature) is deliberate: they keep the answer phase from becoming a homework assignment.
- The BEAM's process-per-game model is a deliberate bet on Phoenix specifically. If this were a React/Node stack, the equivalent would be Durable Objects or a sticky-session GenServer shim, and the complexity budget would be meaningfully larger.
- v2 candidates, in rough priority order: playlist persistence and sharing, the `:guess_for_player` style, user-generated question submissions with a moderation flow, the `:guess_question` style expanded to a first-class citizen with better pool coverage, an automatic fallback to another music service when one can't play, and optional host accounts for saving preferred settings and themes.
- The 20-minute target is a soft guideline. Hosts who crank up questions-per-player will get longer games; that's fine. The default configuration is where the product's quality bar lives.
