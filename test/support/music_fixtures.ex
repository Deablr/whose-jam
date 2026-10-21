defmodule WhoseJam.MusicFixtures do
  @moduledoc """
  One realistic sample per music provider, so tests can run the same
  expectations across every provider (see `WhoseJam.Music.ProviderContractTest`).

  Adding a provider means adding an entry here; the contract test fails until
  you do.
  """

  @samples %{
    spotify: %{
      song: %{
        uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQC",
        name: "Song",
        artist: "Artist",
        album_art_url: "https://i.scdn.co/image/ab67616d0000b273abcdef0123456789"
      },
      auth: %{access_token: "tok", refresh_token: "ref", expires_at: nil, premium?: true},
      ineligible_auth: %{access_token: "tok", premium?: false},
      hostile_art: "https://i.scdn.co/image/abc');color:red"
    },
    mock: %{
      song: %{uri: "mock:track:001", name: "Neon Overdrive", artist: "X", album_art_url: nil},
      auth: %{},
      ineligible_auth: nil,
      hostile_art: "https://example.com/art.png"
    }
  }

  @doc "Sample data for provider `id`: `:song`, `:auth`, `:ineligible_auth`, `:hostile_art`."
  def sample(id), do: Map.fetch!(@samples, id)

  @doc "Ids that have a sample."
  def sample_ids, do: Map.keys(@samples)
end
