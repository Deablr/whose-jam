defmodule WhoseJam.Music.Providers.Mock do
  @moduledoc """
  A fake provider for local development and tests. Enabled via
  `config :whose_jam, :music_providers` in dev/test only.

  Search runs over a tiny in-code catalog (no network, no credentials), the
  host needs no connection step, and the browser "player"
  (`assets/js/hooks/music/mock.js`) plays no audio — it just reports the song
  as ended after a few seconds, which is enough to play a whole game without a
  Spotify account.
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

  @tracks Enum.map(@catalog, fn {id, name, artist} ->
            %{uri: "mock:track:" <> id, name: name, artist: artist, album_art_url: nil}
          end)

  @doc "The full fake catalog."
  @spec tracks() :: [WhoseJam.Music.Track.t()]
  def tracks, do: @tracks

  @impl true
  def id, do: :mock

  @impl true
  def name, do: "Mock Music"

  @impl true
  def requirement, do: "Development only — fake tracks, no real audio."

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
  def valid_uri?(uri), do: Regex.match?(~r/\Amock:track:[0-9]{3}\z/, uri)

  # Mock tracks have no art; nothing is ever valid.
  @impl true
  def valid_art_url?(_url), do: false

  @impl true
  def connect(_params), do: {:ok, %{}}

  @impl true
  def eligible?(_auth), do: true

  @impl true
  def client_config(_auth), do: %{track_ms: @track_ms}
end
