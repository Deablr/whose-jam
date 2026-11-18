# Seeds for whose-jam question pools.
#
# Run with:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: each pool is upserted by theme name (delete-and-reinsert), so
# running this repeatedly leaves the database in the same state.

import Ecto.Query, only: [from: 2]

alias WhoseJam.Content.{Question, Theme}
alias WhoseJam.Repo

now = DateTime.utc_now() |> DateTime.truncate(:second)

# Reseed a theme by name: replace it (and its questions, via on_delete: :delete_all)
# with a fresh theme + question set. `questions` is a list of
# {style, is_example, prompt} tuples.
reseed = fn name, description, style_sequence, questions ->
  Repo.delete_all(from(t in Theme, where: t.name == ^name))

  theme =
    Repo.insert!(%Theme{name: name, description: description, style_sequence: style_sequence})

  rows =
    Enum.map(questions, fn {style, is_example, prompt} ->
      %{
        theme_id: theme.id,
        prompt: prompt,
        style: style,
        is_example: is_example,
        inserted_at: now,
        updated_at: now
      }
    end)

  Repo.insert_all(Question, rows)
  theme
end

# ---------------------------------------------------------------------------
# Pool 1 — "Certified Bangers" (single-style, all :guess_who)
# ~14 gameplay questions + 3 example previews.
# ---------------------------------------------------------------------------

certified_bangers = [
  # Example previews (is_example: true) — never used in actual gameplay.
  {:guess_who, true,
   "The song you’d blast to feel like the main character walking out of a building."},
  {:guess_who, true, "A track that instantly resets your entire mood for the better."},
  {:guess_who, true, "The song you know every single word to, including the ad-libs."},

  # Gameplay questions.
  {:guess_who, false, "The song that turns any car into a concert venue."},
  {:guess_who, false, "The song you’d choose for a dramatic entrance."},
  {:guess_who, false,
   "The one song guaranteed to get you off the couch and onto the dance floor."},
  {:guess_who, false, "A track you’d pick to open the party and set the whole vibe."},
  {:guess_who, false, "The song you crank up when you need to feel unstoppable."},
  {:guess_who, false,
   "A tune that’s objectively too good, no matter how many times it’s overplayed."},
  {:guess_who, false,
   "The song you’d perform at karaoke if you’d had exactly the right number of drinks."},
  {:guess_who, false, "A beat drop so good it should be illegal."},
  {:guess_who, false, "The soundtrack to one summer of your life."},
  {:guess_who, false, "A track you’d put on to convince someone you have great taste."},
  {:guess_who, false, "The song you secretly think is the greatest thing ever recorded."},
  {:guess_who, false, "A tune that makes even the grocery store feel like a movie montage."},
  {:guess_who, false, "The song you’d want playing as you win something in slow motion."},
  {:guess_who, false, "A guilty-pleasure banger you refuse to apologize for."}
]

reseed.(
  "Certified Bangers",
  "Crowd-pleasers only. Everyone picks a song for a prompt, then the room guesses whose it was.",
  [:guess_who],
  certified_bangers
)

# ---------------------------------------------------------------------------
# Pool 2 — "Emotional Damage" (single-style, all :guess_who)
# 18 gameplay questions + 3 example previews. A host who wants more than one
# round picks more than one theme: each theme is its own round.
# ---------------------------------------------------------------------------

emotional_damage = [
  # Example previews.
  {:guess_who, true,
   "The song that would play over the closing credits of a movie about your life."},
  {:guess_who, true, "A song for staring dramatically out of a rain-streaked window."},
  {:guess_who, true, "The track you’d put on to have a good, cathartic cry."},

  # Gameplay.
  {:guess_who, false, "A song for driving away from your problems at night."},
  {:guess_who, false, "The soundtrack to overthinking a text you already sent."},
  {:guess_who, false, "A song that feels like the last day of summer."},
  {:guess_who, false, "The track for lying on the floor questioning every choice you’ve made."},
  {:guess_who, false, "A song for pretending you’re fine at a party."},
  {:guess_who, false, "The tune for a very sad main-character walk in the rain."},
  {:guess_who, false, "A song that would make a stranger cry on public transit."},
  {:guess_who, false, "The track for finally letting go of something you held too long."},
  {:guess_who, false, "The song that reliably makes you tear up no matter where you are."},
  {:guess_who, false, "A track tied to a breakup you’re pretending you’re over."},
  {:guess_who, false, "The song you’d want played at your funeral, purely for the drama."},
  {:guess_who, false,
   "A tune that instantly transports you back to being fifteen and misunderstood."},
  {:guess_who, false, "The song you play on repeat when you’re deep in your feelings."},
  {:guess_who, false,
   "A track that reminds you of someone you probably shouldn’t still think about."},
  {:guess_who, false, "The song that hits differently at 2 a.m."},
  {:guess_who, false, "A tune that makes you miss a version of yourself that no longer exists."},
  {:guess_who, false, "The song you’d text to someone at your absolute lowest."},
  {:guess_who, false, "A track that romanticizes staring longingly into the middle distance."}
]

reseed.(
  "Emotional Damage",
  "The songs that get you every time. Guess who picked each one.",
  [:guess_who],
  emotional_damage
)

# ---------------------------------------------------------------------------
# Pool 3 — "Head to Head" (single-style, all :vs)
# Everyone picks a song for the same prompt; the songs meet two at a time
# until one is left. 10 gameplay prompts (one is drawn per game) + 3 example
# previews.
# ---------------------------------------------------------------------------

head_to_head = [
  # Example previews.
  {:vs, true, "The song that should play when you walk into a party."},
  {:vs, true, "The best song to scream in the car with the windows down."},
  {:vs, true, "The one song you’d save if all the others disappeared."},

  # Gameplay.
  {:vs, false, "The perfect first song of a road trip."},
  {:vs, false, "The ultimate karaoke closer."},
  {:vs, false, "The song that should be playing when the credits roll on tonight."},
  {:vs, false, "The best song to dance to in your kitchen."},
  {:vs, false, "The song most likely to get the whole room singing."},
  {:vs, false, "The greatest song to hear at 1 a.m."},
  {:vs, false, "The best song for the first warm day of the year."},
  {:vs, false, "The song you’d play to win someone over."},
  {:vs, false, "The best song to cook dinner to."},
  {:vs, false, "The perfect song to walk out to before a big fight."}
]

reseed.(
  "Head to Head",
  "Everyone picks a song for the same prompt, then the songs go head to head until one is left.",
  [:vs],
  head_to_head
)

IO.puts("Seeded #{length(Repo.all(Theme))} themes, #{length(Repo.all(Question))} questions.")
