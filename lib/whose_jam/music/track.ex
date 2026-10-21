defmodule WhoseJam.Music.Track do
  @moduledoc """
  Provider-neutral validation of a submitted song.

  The whole song comes from the client, so every field is re-validated here
  before it is stored and rendered on every screen. The provider-specific
  parts (what a valid `uri` and album-art URL look like) are asked of the
  provider; everything else is shared:

    * `uri` must be accepted by the provider's `valid_uri?/1`, otherwise the
      song is rejected with `{:error, :invalid_song}`.
    * `name` / `artist` are display text: non-strings become `""` and strings
      are trimmed and capped at 200 codepoints (not graphemes, so stacked
      combining marks can't bypass the cap; the stored value is at most
      4 * 200 bytes).
    * `album_art_url` is kept only if the provider's `valid_art_url?/1` accepts
      it, otherwise it becomes `nil` — it ends up in every screen's markup.

  Pure: plain data in, plain data out.
  """

  @max_text_length 200

  @type t :: %{
          uri: String.t(),
          name: String.t(),
          artist: String.t(),
          album_art_url: String.t() | nil
        }

  @doc "Validate and normalize `song` (atom- or string-keyed map) for `provider`."
  @spec normalize(module(), term()) :: {:ok, t()} | {:error, :invalid_song}
  def normalize(provider, song) do
    uri = fetch_field(song, :uri)

    if is_binary(uri) and provider.valid_uri?(uri) do
      {:ok,
       %{
         uri: uri,
         name: song |> fetch_field(:name) |> safe_text(),
         artist: song |> fetch_field(:artist) |> safe_text(),
         album_art_url: song |> fetch_field(:album_art_url) |> safe_art_url(provider)
       }}
    else
      {:error, :invalid_song}
    end
  end

  # Fetch a value from a map that may use atom or string keys.
  defp fetch_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_field(_map, _key), do: nil

  defp safe_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    binary_part(trimmed, 0, codepoint_prefix_size(trimmed, @max_text_length, 0))
  end

  defp safe_text(_text), do: ""

  # Byte size of the first `n` codepoints of `text`.
  defp codepoint_prefix_size(_text, 0, size), do: size

  defp codepoint_prefix_size(text, n, size) do
    case String.next_codepoint(text) do
      nil -> size
      {codepoint, rest} -> codepoint_prefix_size(rest, n - 1, size + byte_size(codepoint))
    end
  end

  defp safe_art_url(url, provider) when is_binary(url) do
    if provider.valid_art_url?(url), do: url, else: nil
  end

  defp safe_art_url(_url, _provider), do: nil
end
