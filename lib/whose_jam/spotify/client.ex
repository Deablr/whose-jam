defmodule WhoseJam.Spotify.Client do
  @moduledoc """
  Low-level HTTP client for the Spotify Web API.

  Pure request/response helpers — no caching, no processes. All HTTP goes
  through `req`. The provider (`WhoseJam.Music.Providers.Spotify`) and
  `WhoseJam.Music.Cache` layer token caching and result caching on top of
  these functions.

  This module implements the **app-level Client Credentials flow**: an
  application token (not tied to any host account) used only for track search.
  Host-account OAuth lives in `WhoseJam.Spotify.Auth`.
  """

  alias WhoseJam.Spotify.Credentials

  @search_url "https://api.spotify.com/v1/search"
  @search_limit 8

  @type track :: WhoseJam.Music.Track.t()

  @doc """
  Fetches a fresh app-level access token via the Client Credentials flow.

  ## Returns

    * `{:ok, %{access_token: String.t(), expires_in: pos_integer()}}` on success
      (`expires_in` is the token lifetime in seconds, typically 3600).
    * `{:error, :not_configured}` when app credentials are absent.
    * `{:error, term()}` on transport or non-2xx responses.
  """
  @spec fetch_app_token() ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer()}}
          | {:error, term()}
  def fetch_app_token do
    with {:ok, creds} <- Credentials.fetch() do
      Credentials.token_url()
      |> Req.post(
        form: [grant_type: "client_credentials"],
        auth: Credentials.basic_auth(creds),
        receive_timeout: Credentials.receive_timeout()
      )
      |> Credentials.handle_json(&extract_app_token/1)
    end
  end

  @doc """
  Searches Spotify for tracks matching `query`.

  Requires a valid bearer token (app-level or host-level). Returns up to
  #{@search_limit} normalized track maps.

  ## Returns

    * `{:ok, [track()]}` — a (possibly empty) list of track maps with keys
      `:uri`, `:name`, `:artist`, `:album_art_url`.
    * `{:error, term()}` on transport or non-2xx responses.
  """
  @spec search_tracks(String.t(), String.t()) :: {:ok, [track()]} | {:error, term()}
  def search_tracks(access_token, query) when is_binary(access_token) do
    @search_url
    |> Req.get(
      params: [q: query, type: "track", limit: @search_limit],
      auth: {:bearer, access_token},
      receive_timeout: Credentials.receive_timeout()
    )
    |> Credentials.handle_json(&extract_tracks/1)
  end

  defp extract_app_token(body) do
    case body do
      %{"access_token" => token, "expires_in" => expires_in}
      when is_binary(token) and is_integer(expires_in) ->
        {:ok, %{access_token: token, expires_in: expires_in}}

      _ ->
        {:error, {:unexpected_token_body, body}}
    end
  end

  defp extract_tracks(body) do
    items =
      body
      |> Map.get("tracks", %{})
      |> Map.get("items", [])

    {:ok, Enum.map(items, &normalize_track/1)}
  end

  defp normalize_track(track) do
    %{
      uri: track["uri"],
      name: track["name"],
      artist: artist_names(track),
      album_art_url: album_art_url(track)
    }
  end

  defp artist_names(track) do
    track
    |> Map.get("artists", [])
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  # Spotify returns images sorted largest-first (e.g. 640, 300, 64). Pick the
  # largest: the submitted song's art is shown big on the TV, where the 64px
  # thumbnail looked badly pixelated. Phones scale it down fine.
  defp album_art_url(track) do
    track
    |> get_in(["album", "images"])
    |> case do
      images when is_list(images) and images != [] ->
        images |> Enum.max_by(&(&1["width"] || 0)) |> Map.get("url")

      _ ->
        nil
    end
  end
end
