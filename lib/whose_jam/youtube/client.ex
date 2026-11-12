defmodule WhoseJam.YouTube.Client do
  @moduledoc """
  Song search against the YouTube Data API v3 (`search.list`), with the
  server's API key.

  Only music videos that can be embedded are returned — the host screen plays
  them in the IFrame player, and a video whose owner has disabled embedding
  would fail there.

  ## Quota

  Google allows a Cloud project roughly 100 searches a day by default. When
  that is used up `search_videos/1` returns `{:error, :quota_exceeded}`, which
  the player screen words differently from a network failure.
  `WhoseJam.Music` caches results and the provider asks for a longer search
  debounce, both to make the allowance last.

  ## Failures

  Players only see a generic "couldn't reach the music service", so every
  failed request is logged with Google's own explanation (a key restricted to
  HTTP referrers, the API not enabled on the project, ...). The key is sent as
  a query parameter and is never part of what is logged.
  """

  alias WhoseJam.YouTube.Credentials

  require Logger

  @search_url "https://www.googleapis.com/youtube/v3/search"
  @search_limit 8

  # The Data API's "Music" video category.
  @music_category "10"

  # The allowance for the day is gone. Short-term throttles (`rateLimitExceeded`,
  # `userRateLimitExceeded`) are not in this list: they clear in seconds, so
  # players should be told to try again, not that search is over for today.
  @quota_reasons ~w(quotaExceeded dailyLimitExceeded)

  @video_id_regex ~r/\A[A-Za-z0-9_-]{11}\z/

  @type track :: WhoseJam.Music.Track.t()

  @doc """
  Searches YouTube for music videos matching `query`.

  ## Returns

    * `{:ok, [track()]}` — up to #{@search_limit} tracks.
    * `{:error, :not_configured}` — no API key.
    * `{:error, :quota_exceeded}` — the project's search allowance for the day
      is used up.
    * `{:error, term()}` on transport or other non-2xx responses.
  """
  @spec search_videos(String.t()) :: {:ok, [track()]} | {:error, term()}
  def search_videos(query) when is_binary(query) do
    with {:ok, key} <- Credentials.fetch_api_key() do
      @search_url
      |> Req.get(
        params: [
          part: "snippet",
          type: "video",
          videoCategoryId: @music_category,
          videoEmbeddable: "true",
          videoSyndicated: "true",
          maxResults: @search_limit,
          q: query,
          key: key
        ],
        # Req would retry a 429/5xx or a dropped connection up to three times.
        # Each retry spends quota again and keeps the player's screen waiting.
        retry: false,
        receive_timeout: Credentials.receive_timeout()
      )
      |> handle_response()
    end
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) when is_map(body),
    do: {:ok, tracks_from_search(body)}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.warning("YouTube search failed: HTTP #{status} — #{error_message(body)}")

    if quota_exceeded?(body),
      do: {:error, :quota_exceeded},
      else: {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}) do
    Logger.warning("YouTube search failed: #{inspect(reason)}")
    {:error, reason}
  end

  # Google's one-line explanation, e.g. "Requests from referer <empty> are blocked."
  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(_body), do: "no explanation in the response"

  @doc """
  Whether a Data API error `body` says the project's allowance for the day is
  used up.

  Google reports it as a 403 whose `error.errors[].reason` is `quotaExceeded`
  or `dailyLimitExceeded`. A short-term throttle (`rateLimitExceeded`) is not
  the daily allowance and is left as an ordinary, retryable failure.
  """
  @spec quota_exceeded?(term()) :: boolean()
  def quota_exceeded?(%{"error" => %{"errors" => errors}}) when is_list(errors) do
    Enum.any?(errors, fn
      %{"reason" => reason} -> reason in @quota_reasons
      _other -> false
    end)
  end

  def quota_exceeded?(_body), do: false

  @doc """
  Maps a decoded `search.list` response `body` to tracks.

  Pure. A track's `uri` is `youtube:video:<id>`, its `name` the video title,
  its `artist` the channel (without YouTube's auto-generated " - Topic"
  suffix) and its `album_art_url` the largest thumbnail on offer. The Data API
  returns titles HTML-escaped (`Guns N&#39; Roses`), so they are decoded here.
  Items without a well-formed video id are dropped.
  """
  @spec tracks_from_search(map()) :: [track()]
  def tracks_from_search(body) when is_map(body) do
    case Map.get(body, "items") do
      items when is_list(items) -> Enum.flat_map(items, &track/1)
      _other -> []
    end
  end

  defp track(%{"id" => %{"videoId" => id}} = item) when is_binary(id) do
    if Regex.match?(@video_id_regex, id) do
      snippet = snippet_of(item)

      [
        %{
          uri: "youtube:video:" <> id,
          name: snippet |> Map.get("title") |> text(),
          artist: snippet |> Map.get("channelTitle") |> text() |> strip_topic(),
          album_art_url: thumbnail(snippet)
        }
      ]
    else
      []
    end
  end

  defp track(_item), do: []

  defp snippet_of(%{"snippet" => snippet}) when is_map(snippet), do: snippet
  defp snippet_of(_item), do: %{}

  defp text(value) when is_binary(value), do: decode_entities(value)
  defp text(_value), do: ""

  # Auto-generated artist channels are named "<Artist> - Topic".
  defp strip_topic(channel), do: String.replace_suffix(channel, " - Topic", "")

  defp thumbnail(snippet) do
    with thumbnails when is_map(thumbnails) <- Map.get(snippet, "thumbnails"),
         %{"url" => url} when is_binary(url) <-
           thumbnails["high"] || thumbnails["medium"] || thumbnails["default"] do
      url
    else
      _ -> nil
    end
  end

  @named_entities %{"amp" => "&", "quot" => "\"", "apos" => "'", "lt" => "<", "gt" => ">"}

  # The handful of entities the Data API emits, plus numeric references. One
  # pass, so "&amp;lt;" decodes to the literal text "&lt;" rather than "<".
  # The result is plain text: HEEx escapes it again wherever it is rendered.
  defp decode_entities(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-z]+);/, text, fn whole, entity ->
      decode_entity(entity) || whole
    end)
  end

  defp decode_entity("#x" <> hex), do: codepoint(hex, 16)
  defp decode_entity("#" <> decimal), do: codepoint(decimal, 10)
  defp decode_entity(name), do: Map.get(@named_entities, name)

  defp codepoint(digits, base) do
    case Integer.parse(digits, base) do
      {codepoint, ""} -> utf8(codepoint)
      _other -> nil
    end
  end

  # `nil` for anything that isn't a valid Unicode scalar value.
  defp utf8(codepoint) when codepoint in 0xD800..0xDFFF or codepoint > 0x10FFFF, do: nil
  defp utf8(0), do: nil
  defp utf8(codepoint), do: <<codepoint::utf8>>
end
