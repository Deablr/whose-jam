defmodule WhoseJam.Spotify.Playlists do
  @moduledoc """
  Saving a playlist to the host's Spotify account, with an access token from
  the one-off playlist sign-in (`WhoseJam.Spotify.Auth.playlist_authorize_url/2`,
  scope `playlist-modify-public`). The token is used for these two requests
  and then dropped.

  The playlist is public, so that the link the TV shows as a QR code opens
  for everyone in the room (a private Spotify playlist opens only for its
  owner). Uses the Web API's current endpoints (`POST /me/playlists`, then
  `POST /playlists/{id}/items`, which takes at most 100 URIs a request).
  """

  alias WhoseJam.Spotify.Credentials

  @create_url "https://api.spotify.com/v1/me/playlists"
  @items_batch 100

  @doc """
  Make a public playlist called `name` of `uris` (Spotify track URIs, in
  order) and return its link (`https://open.spotify.com/playlist/…`).
  """
  @spec create(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def create(access_token, name, description, uris) when is_binary(access_token) do
    with {:ok, %{id: id, url: url}} <- new_playlist(access_token, name, description),
         :ok <- add_items(access_token, id, uris) do
      {:ok, url}
    end
  end

  defp new_playlist(access_token, name, description) do
    @create_url
    |> Req.post(
      json: %{name: name, description: description, public: true},
      auth: {:bearer, access_token},
      receive_timeout: Credentials.receive_timeout()
    )
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        playlist_link(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp playlist_link(%{"id" => id, "external_urls" => %{"spotify" => "https://" <> _ = url}})
       when is_binary(id),
       do: {:ok, %{id: id, url: url}}

  defp playlist_link(%{"id" => id}) when is_binary(id),
    do: {:ok, %{id: id, url: "https://open.spotify.com/playlist/" <> URI.encode(id)}}

  defp playlist_link(body), do: {:error, {:unexpected_playlist_body, body}}

  defp add_items(access_token, id, uris) do
    uris
    |> Enum.chunk_every(@items_batch)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case add_batch(access_token, id, batch) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp add_batch(access_token, id, uris) do
    "https://api.spotify.com/v1/playlists/#{URI.encode(id)}/items"
    |> Req.post(
      json: %{uris: uris},
      auth: {:bearer, access_token},
      receive_timeout: Credentials.receive_timeout()
    )
    |> case do
      {:ok, %Req.Response{status: status}} when status in [200, 201] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
