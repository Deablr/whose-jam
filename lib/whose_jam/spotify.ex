defmodule WhoseJam.Spotify do
  @moduledoc """
  Public facade for the Spotify integration.

  Two independent concerns live behind this namespace:

    * **Track search** (this module's `search/1`) — server-side, app-level
      Client Credentials flow. The app token and search results are cached in
      memory by `WhoseJam.Spotify.Cache`. The secret never leaves the server.

    * **Host OAuth** (`WhoseJam.Spotify.Auth`) — Authorization Code flow used to
      authenticate the host's Premium account for the Web Playback SDK.

  ## Configuration

  Credentials come from `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET`, read at
  runtime. When they are absent, `search/1` returns `{:error, :not_configured}`
  cleanly rather than crashing — a dev box without creds still boots and runs.

  ## Supervision

  `WhoseJam.Spotify.Cache` must be added to the supervision tree for search
  caching to work. See that module's docs for the child spec.
  """

  alias WhoseJam.Spotify.{Cache, Client, Credentials}

  @type track :: %{
          uri: String.t(),
          name: String.t(),
          artist: String.t(),
          album_art_url: String.t() | nil
        }

  @doc """
  Searches Spotify for tracks matching `query`.

  Returns up to 8 tracks. Results are served from an in-memory cache keyed by
  the normalized query (case-insensitive, whitespace-collapsed) with a short
  TTL, so repeated identical searches don't hit the Spotify API. The app token
  is fetched and refreshed transparently.

  ## Returns

    * `{:ok, [track()]}` — a list of maps with keys `:uri`, `:name`, `:artist`,
      `:album_art_url` (`album_art_url` may be `nil`). A blank query returns
      `{:ok, []}` without any network call.
    * `{:error, :not_configured}` — Spotify credentials are not set.
    * `{:error, term()}` — token fetch or search request failed.

  ## Examples

      iex> WhoseJam.Spotify.search("never gonna give you up")
      {:ok, [%{uri: "spotify:track:...", name: "...", artist: "...", album_art_url: "..."}]}
  """
  @spec search(String.t()) :: {:ok, [track()]} | {:error, term()}
  def search(query) when is_binary(query) do
    normalized = normalize(query)

    cond do
      normalized == "" ->
        {:ok, []}

      not Credentials.configured?() ->
        {:error, :not_configured}

      true ->
        do_search(query, normalized)
    end
  end

  defp do_search(query, normalized) do
    case Cache.get_cached_search(normalized) do
      {:ok, results} ->
        {:ok, results}

      :miss ->
        with {:ok, token} <- Cache.get_app_token(),
             {:ok, results} <- Client.search_tracks(token, query) do
          Cache.put_cached_search(normalized, results)
          {:ok, results}
        end
    end
  end

  # Case-insensitive, trimmed, internal whitespace collapsed to single spaces,
  # so "  Bohemian   RHAPSODY " and "bohemian rhapsody" share a cache entry.
  defp normalize(query) do
    query
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end
end
