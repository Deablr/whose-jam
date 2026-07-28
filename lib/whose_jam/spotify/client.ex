defmodule WhoseJam.Spotify.Client do
  @moduledoc """
  Low-level HTTP client for the Spotify Web API.

  Pure request/response helpers — no caching, no processes. All HTTP goes
  through `req`. Callers (the cache and the facade) layer token caching and
  result caching on top of these functions.

  This module implements the **app-level Client Credentials flow**: an
  application token (not tied to any host account) used only for track search.
  Host-account OAuth lives in `WhoseJam.Spotify.Auth`.
  """

  alias WhoseJam.Spotify.Credentials

  @token_url "https://accounts.spotify.com/api/token"
  @search_url "https://api.spotify.com/v1/search"
  @search_limit 8
  @receive_timeout 8_000

  @type track :: %{
          uri: String.t(),
          name: String.t(),
          artist: String.t(),
          album_art_url: String.t() | nil
        }

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
    with {:ok, %{client_id: id, client_secret: secret}} <- Credentials.fetch() do
      @token_url
      |> Req.post(
        form: [grant_type: "client_credentials"],
        auth: {:basic, "#{id}:#{secret}"},
        receive_timeout: @receive_timeout
      )
      |> handle_token_response()
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
      receive_timeout: @receive_timeout
    )
    |> handle_search_response()
  end

  defp handle_token_response({:ok, %Req.Response{status: 200, body: body}})
       when is_map(body) do
    case body do
      %{"access_token" => token, "expires_in" => expires_in}
      when is_binary(token) and is_integer(expires_in) ->
        {:ok, %{access_token: token, expires_in: expires_in}}

      _ ->
        {:error, {:unexpected_token_body, body}}
    end
  end

  defp handle_token_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_token_response({:error, reason}), do: {:error, reason}

  defp handle_search_response({:ok, %Req.Response{status: 200, body: body}})
       when is_map(body) do
    items =
      body
      |> Map.get("tracks", %{})
      |> Map.get("items", [])

    {:ok, Enum.map(items, &normalize_track/1)}
  end

  defp handle_search_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_search_response({:error, reason}), do: {:error, reason}

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
  # smallest available — a thumbnail is plenty for phone search results.
  defp album_art_url(track) do
    track
    |> get_in(["album", "images"])
    |> case do
      images when is_list(images) and images != [] ->
        images |> List.last() |> Map.get("url")

      _ ->
        nil
    end
  end
end
