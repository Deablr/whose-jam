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
   "The song you'd blast to feel like the main character walking out of a building."},
  {:guess_who, true, "A track that instantly resets your entire mood for the better."},
  {:guess_who, true, "The song you know every single word to, including the ad-libs."},

  # Gameplay questions.
  {:guess_who, false, "The song that turns any car into a concert venue."},
  {:guess_who, false, "A banger you'd be a little embarrassed to admit is on your gym playlist."},
  {:guess_who, false,
   "The one song guaranteed to get you off the couch and onto the dance floor."},
  {:guess_who, false, "A track you'd pick to open the party and set the whole vibe."},
  {:guess_who, false, "The song you crank up when you need to feel unstoppable."},
  {:guess_who, false,
   "A tune that's objectively too good, no matter how many times it's overplayed."},
  {:guess_who, false,
   "The song you'd perform at karaoke if you'd had exactly the right number of drinks."},
  {:guess_who, false, "A beat drop so good it should be illegal."},
  {:guess_who, false,
   "The song that was undeniably the soundtrack of one specific summer of your life."},
  {:guess_who, false, "A track you'd put on to convince someone you have great taste."},
  {:guess_who, false, "The song you secretly think is the greatest thing ever recorded."},
  {:guess_who, false, "A tune that makes even the grocery store feel like a movie montage."},
  {:guess_who, false, "The song you'd want playing as you win something in slow motion."},
  {:guess_who, false, "A guilty-pleasure banger you refuse to apologize for."}
]

reseed.(
  "Certified Bangers",
  "Pure, unfiltered hype. Every prompt is a hunt for the biggest banger in your friends' libraries — then guess who dropped it.",
  [:guess_who],
  certified_bangers
)

# ---------------------------------------------------------------------------
# Pool 2 — "Emotional Damage" (multi-style: :guess_who then :guess_question)
# ~10 :guess_who + ~8 :guess_question gameplay questions + 3 example previews.
# ---------------------------------------------------------------------------

emotional_damage = [
  # Example previews (mix of both styles).
  {:guess_who, true,
   "The song that would play over the closing credits of a movie about your life."},
  {:guess_question, true, "A song for staring dramatically out of a rain-streaked window."},
  {:guess_question, true, "The track you'd put on to have a good, cathartic cry."},

  # Sub-round 1 — :guess_who (guess which friend submitted this).
  {:guess_who, false, "The song that reliably makes you tear up no matter where you are."},
  {:guess_who, false, "A track tied to a breakup you're pretending you're over."},
  {:guess_who, false, "The song you'd want played at your funeral, purely for the drama."},
  {:guess_who, false,
   "A tune that instantly transports you back to being fifteen and misunderstood."},
  {:guess_who, false, "The song you play on repeat when you're deep in your feelings."},
  {:guess_who, false,
   "A track that reminds you of someone you probably shouldn't still think about."},
  {:guess_who, false, "The song that hits differently at 2 a.m."},
  {:guess_who, false, "A tune that makes you miss a version of yourself that no longer exists."},
  {:guess_who, false, "The song you'd text to someone at your absolute lowest."},
  {:guess_who, false, "A track that romanticizes staring longingly into the middle distance."},

  # Sub-round 2 — :guess_question (guess which prompt the song answers).
  {:guess_question, false, "A song for driving away from your problems at night."},
  {:guess_question, false, "The soundtrack to overthinking a text you already sent."},
  {:guess_question, false, "A song that feels like the last day of summer."},
  {:guess_question, false,
   "The track for lying on the floor questioning every choice you've made."},
  {:guess_question, false, "A song for pretending you're fine at a party."},
  {:guess_question, false, "The tune for a very sad main-character walk in the rain."},
  {:guess_question, false, "A song that would make a stranger cry on public transit."},
  {:guess_question, false, "The track for finally letting go of something you held too long."}
]

reseed.(
  "Emotional Damage",
  "For when the vibe gets tender. Two sub-rounds: first guess who bared their soul, then guess which prompt each gut-punch of a song was answering.",
  [:guess_who, :guess_question],
  emotional_damage
)

IO.puts("Seeded #{length(Repo.all(Theme))} themes, #{length(Repo.all(Question))} questions.")
