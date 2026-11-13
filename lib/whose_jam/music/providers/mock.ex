defmodule WhoseJam.Music.Providers.Mock do
  @moduledoc """
  A fake provider for local development and tests. Enabled via
  `config :whose_jam, :music_providers` in dev/test only.

  Search runs over a tiny in-code catalog (no network, no credentials), and
  the host needs no connection step. Most tracks are made up: the browser
  "player" (`assets/js/hooks/music/mock.js`) plays nothing for them and just
  reports the song as ended after a few seconds, which is enough to play a
  whole game without a Spotify account. A few are real songs from
  NoCopyrightSounds (`ncs_tracks/0`), played for real, at their real length,
  when their audio file is present in `priv/static/audio/mock/` (it is kept
  out of git: `mix test.e2e` copies it from a local folder of the NCS
  downloads, see `README.md`); without it, they behave like the made-up ones.

  Every track has cover art, as a real service's tracks do: a placeholder
  picture served by this app (`priv/static/images/mock/<id>.svg`), so the
  screens look in development the way they do in a real game.
  """

  @behaviour WhoseJam.Music.Provider

  # How long the browser stub "plays" each song before reporting it ended.
  @track_ms 5_000

  @catalog [
    {"001", "Neon Overdrive", "The Synthetics"},
    {"002", "Paper Planes at Midnight", "Lucy Marlowe"},
    {"003", "Slow Burn Sunday", "Harbor & Haze"},
    {"004", "Concrete Garden", "Okonkwo"},
    {"005", "Rewind to Summer", "The Synthetics"},
    {"006", "Static in the Stars", "Mira Vance"},
    {"007", "Backseat Karaoke", "Pocket Orchestra"},
    {"008", "Golden Hour Hangover", "Lucy Marlowe"}
  ]

  # Real songs, free to use with credit ("Music provided by
  # NoCopyrightSounds"; see priv/static/audio/mock/CREDITS.txt): {id, name,
  # artist, the NCS download's file name}.
  @ncs [
    {"009", "Re:バース (Re:Verse)", "439*hz", "439_hz - Re_バース (Re_Verse) [NCS Release].mp3"},
    {"010", "FLIRT (if i don’t mean it)", "Alie & HIKING",
     "Alie, HIKING - FLIRT (if i don’t mean it) [NCS Release].mp3"},
    {"011", "Happier Now", "SadBois & Gabriel Eli",
     "Gabriel Eli, SadBois - Happier Now [NCS Release].mp3"},
    {"012", "Anesthesia", "Oxlo", "Oxlo - Anesthesia [NCS Release].mp3"},
    {"013", "デイドリーム (Daydream)", "RINZO & Mahiru",
     "RINZO, MAHIRU - デイドリーム (Daydream) [NCS Release].mp3"},
    {"014", "Severed Rose", "SlidV & Clarx", "SlidV, Clarx - Severed Rose [NCS Release].mp3"}
  ]

  @tracks Enum.map(
            @catalog ++ Enum.map(@ncs, fn {id, name, artist, _file} -> {id, name, artist} end),
            fn {id, name, artist} ->
              %{
                uri: "mock:track:" <> id,
                name: name,
                artist: artist,
                album_art_url: "/images/mock/" <> id <> ".svg"
              }
            end
          )

  # Where the browser finds each real song's audio, by URI.
  @audio Map.new(@ncs, fn {id, _name, _artist, _file} ->
           {"mock:track:" <> id, "/audio/mock/" <> id <> ".mp3"}
         end)

  @doc "The full catalog: the made-up tracks, then the real ones."
  @spec tracks() :: [WhoseJam.Music.Track.t()]
  def tracks, do: @tracks

  @doc """
  The real songs: `{id, download_file_name}` for each, the audio served at
  `/audio/mock/<id>.mp3` when it has been copied into
  `priv/static/audio/mock/` (as `mix test.e2e` does).
  """
  @spec ncs_tracks() :: [{String.t(), String.t()}]
  def ncs_tracks, do: Enum.map(@ncs, fn {id, _name, _artist, file} -> {id, file} end)

  @impl true
  def id, do: :mock

  @impl true
  def name, do: "Mock Music"

  @impl true
  def requirement, do: "Development only: a small catalogue, mostly made up."

  @impl true
  def ineligible_message, do: "The mock service is always eligible."

  @impl true
  def connect_kind, do: :none

  @impl true
  def video?, do: false

  @impl true
  def configured?, do: true

  @impl true
  def search(query, _auth) do
    needle = String.downcase(query)

    {:ok,
     Enum.filter(@tracks, fn track ->
       String.contains?(String.downcase(track.name <> " " <> track.artist), needle)
     end)}
  end

  @impl true
  def search_debounce_ms, do: 300

  @impl true
  def valid_uri?(uri), do: Regex.match?(~r/\Amock:track:[0-9]{3}\z/, uri)

  # Only this app's own placeholder covers: a path, so never another origin.
  @impl true
  def valid_art_url?(url) when is_binary(url),
    do: Regex.match?(~r"\A/images/mock/[0-9]{3}\.svg\z", url)

  def valid_art_url?(_url), do: false

  @impl true
  def connect(_params), do: {:ok, %{}}

  @impl true
  def eligible?(_auth), do: true

  @impl true
  def client_config(_auth), do: %{track_ms: @track_ms, audio: @audio}
end
