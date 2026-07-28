defmodule WhoseJam.Spotify.Credentials do
  @moduledoc """
  Reads Spotify app credentials from the environment at runtime.

  Credentials are **never** compiled in. They are read fresh from
  `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` on every call via
  `System.get_env/1`, so a dev box without them configured degrades gracefully
  (callers receive `{:error, :not_configured}`) rather than crashing at boot.

  Also the single home for shared token-endpoint constants
  (`token_url/0`, `receive_timeout/0`) and the basic-auth header builder
  (`basic_auth/1`) used by both the app-level client and host OAuth flows.
  """

  @token_url "https://accounts.spotify.com/api/token"
  @receive_timeout 8_000

  @doc "Spotify's OAuth token endpoint (shared by the Client Credentials and Authorization Code flows)."
  @spec token_url() :: String.t()
  def token_url, do: @token_url

  @doc "Default `receive_timeout` (ms) for Spotify token requests."
  @spec receive_timeout() :: pos_integer()
  def receive_timeout, do: @receive_timeout

  @doc """
  Builds the `Req` HTTP Basic auth tuple from credentials.

  Accepts the credentials map returned by `fetch/0`.
  """
  @spec basic_auth(%{client_id: String.t(), client_secret: String.t()}) ::
          {:basic, String.t()}
  def basic_auth(%{client_id: id, client_secret: secret}), do: {:basic, "#{id}:#{secret}"}

  @doc """
  Shared status-cascade for Spotify JSON responses.

  Takes the raw `Req` result and an `extractor` that maps a decoded 200 body
  (a map) to the caller's success/failure tuple. Non-200 responses become
  `{:error, {:http_error, status, body}}` and transport errors pass through as
  `{:error, reason}`, so every caller shares the same error shapes.
  """
  @spec handle_json(
          {:ok, Req.Response.t()} | {:error, term()},
          (map() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  def handle_json({:ok, %Req.Response{status: 200, body: body}}, extractor)
      when is_map(body) and is_function(extractor, 1) do
    extractor.(body)
  end

  def handle_json({:ok, %Req.Response{status: status, body: body}}, _extractor),
    do: {:error, {:http_error, status, body}}

  def handle_json({:error, reason}, _extractor), do: {:error, reason}

  @doc """
  Returns the configured Spotify app credentials.

  ## Returns

    * `{:ok, %{client_id: String.t(), client_secret: String.t()}}` when both
      env vars are present and non-blank.
    * `{:error, :not_configured}` when either is missing or blank.
  """
  @spec fetch() ::
          {:ok, %{client_id: String.t(), client_secret: String.t()}}
          | {:error, :not_configured}
  def fetch do
    with id when is_binary(id) <- System.get_env("SPOTIFY_CLIENT_ID"),
         secret when is_binary(secret) <- System.get_env("SPOTIFY_CLIENT_SECRET"),
         false <- blank?(id),
         false <- blank?(secret) do
      {:ok, %{client_id: id, client_secret: secret}}
    else
      _ -> {:error, :not_configured}
    end
  end

  @doc """
  Returns `true` when both Spotify env vars are configured, `false` otherwise.

  Useful for host-facing "Spotify is/ isn't set up" checks without needing the
  actual secret values.
  """
  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, _}, fetch())
  end

  defp blank?(value), do: String.trim(value) == ""
end
