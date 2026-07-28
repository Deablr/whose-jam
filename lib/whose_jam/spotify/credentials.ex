defmodule WhoseJam.Spotify.Credentials do
  @moduledoc """
  Reads Spotify app credentials from the environment at runtime.

  Credentials are **never** compiled in. They are read fresh from
  `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` on every call via
  `System.get_env/1`, so a dev box without them configured degrades gracefully
  (callers receive `{:error, :not_configured}`) rather than crashing at boot.
  """

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
