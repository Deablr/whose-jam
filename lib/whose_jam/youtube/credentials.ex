defmodule WhoseJam.YouTube.Credentials do
  @moduledoc """
  Reads the Google Cloud credentials the YouTube provider needs, from the
  environment at runtime.

  Two independent credentials, both from the same Google Cloud project:

    * `YOUTUBE_API_KEY` — an API key with the YouTube Data API v3 enabled, used
      server-side for song search. It never reaches a browser.
    * `YOUTUBE_CLIENT_ID` / `YOUTUBE_CLIENT_SECRET` — an OAuth 2.0 "Web
      application" client, used for the host's Google sign-in.

  Nothing is compiled in: every call reads `System.get_env/1`, so a machine
  without them degrades gracefully (`{:error, :not_configured}`) rather than
  crashing at boot.
  """

  @receive_timeout 8_000

  @type oauth_client :: %{client_id: String.t(), client_secret: String.t()}

  @doc "Default `receive_timeout` (ms) for Google requests."
  @spec receive_timeout() :: pos_integer()
  def receive_timeout, do: @receive_timeout

  @doc "The Data API key, or `{:error, :not_configured}` when it is missing or blank."
  @spec fetch_api_key() :: {:ok, String.t()} | {:error, :not_configured}
  def fetch_api_key, do: fetch_env("YOUTUBE_API_KEY")

  @doc "The OAuth client, or `{:error, :not_configured}` when either half is missing or blank."
  @spec fetch_oauth_client() :: {:ok, oauth_client()} | {:error, :not_configured}
  def fetch_oauth_client do
    with {:ok, id} <- fetch_env("YOUTUBE_CLIENT_ID"),
         {:ok, secret} <- fetch_env("YOUTUBE_CLIENT_SECRET") do
      {:ok, %{client_id: id, client_secret: secret}}
    end
  end

  @doc "Whether the API key and the OAuth client are all present."
  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, _}, fetch_api_key()) and match?({:ok, _}, fetch_oauth_client())
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, :not_configured}, else: {:ok, value}

      nil ->
        {:error, :not_configured}
    end
  end
end
