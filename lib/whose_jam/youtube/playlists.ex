defmodule WhoseJam.YouTube.Playlists do
  @moduledoc """
  Saving a playlist to the host's YouTube account, with an access token from
  the one-off playlist sign-in (`WhoseJam.YouTube.Auth.playlist_authorize_url/2`,
  scope `youtube`). The token is used for these requests and then dropped:
  the game still keeps no Google token.

  The playlist is unlisted, so the link the TV shows as a QR code opens for
  everyone in the room without the playlist showing on the host's channel.

  ## Quota

  Each request costs 50 units of the project's daily allowance (one for the
  playlist and one per song): a night of 16 songs costs as much as about
  eight searches.
  """

  alias WhoseJam.YouTube.Credentials

  @playlists_url "https://www.googleapis.com/youtube/v3/playlists"
  @items_url "https://www.googleapis.com/youtube/v3/playlistItems"

  @doc """
  Make an unlisted playlist called `name` of `video_ids` (in order) and
  return its link (`https://www.youtube.com/playlist?list=…`).
  """
  @spec create(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def create(access_token, name, description, video_ids) when is_binary(access_token) do
    with {:ok, id} <- new_playlist(access_token, name, description),
         :ok <- add_videos(access_token, id, video_ids) do
      {:ok, "https://www.youtube.com/playlist?" <> URI.encode_query(list: id)}
    end
  end

  defp new_playlist(access_token, name, description) do
    @playlists_url
    |> Req.post(
      params: [part: "snippet,status"],
      json: %{
        snippet: %{title: name, description: description},
        status: %{privacyStatus: "unlisted"}
      },
      auth: {:bearer, access_token},
      receive_timeout: Credentials.receive_timeout()
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"id" => id}}} when is_binary(id) -> {:ok, id}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # One request per video (the API takes no batches), in order, stopping at
  # the first failure.
  defp add_videos(access_token, playlist_id, video_ids) do
    Enum.reduce_while(video_ids, :ok, fn video_id, :ok ->
      case add_video(access_token, playlist_id, video_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp add_video(access_token, playlist_id, video_id) do
    @items_url
    |> Req.post(
      params: [part: "snippet"],
      json: %{
        snippet: %{
          playlistId: playlist_id,
          resourceId: %{kind: "youtube#video", videoId: video_id}
        }
      },
      auth: {:bearer, access_token},
      receive_timeout: Credentials.receive_timeout()
    )
    |> case do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
