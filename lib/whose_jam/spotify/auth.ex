defmodule WhoseJam.Spotify.Auth do
  @moduledoc """
  Host-account Spotify OAuth (Authorization Code flow).

  Used to authenticate the host's **Premium** account so the TV browser can
  drive the Web Playback SDK. This is entirely separate from the app-level
  Client Credentials token used for search (`WhoseJam.Spotify`).

  ## Flow

    1. Redirect the host to `authorize_url/2`.
    2. Spotify redirects back to your `redirect_uri` with `code` and `state`.
    3. Call `exchange_code/2` to get access + refresh tokens.
    4. Call `premium?/1` to verify the account is Premium (required to host).
    5. Later, call `refresh/1` with the stored refresh token to get a new
       access token when the old one nears expiry.

  All token maps carry `expires_at` as a `DateTime` (UTC), so callers can
  compare against `DateTime.utc_now/0` to decide when to refresh.

  Credentials are read from the environment at runtime; every function returns
  `{:error, :not_configured}` when they are absent.
  """

  alias WhoseJam.Spotify.Credentials

  @authorize_url "https://accounts.spotify.com/authorize"
  @token_url "https://accounts.spotify.com/api/token"
  @me_url "https://api.spotify.com/v1/me"
  @receive_timeout 8_000

  # Scopes required for the Web Playback SDK and playback control.
  @scopes "streaming user-read-email user-read-private user-modify-playback-state user-read-playback-state"

  @doc """
  Builds the Spotify authorization URL to redirect the host to.

  `state` is an opaque CSRF token you generate and later verify on the
  redirect. `redirect_uri` must exactly match one registered in the Spotify app
  dashboard.

  Returns `{:error, :not_configured}` when credentials are absent, otherwise the
  URL string.
  """
  @spec authorize_url(String.t(), String.t()) :: String.t() | {:error, :not_configured}
  def authorize_url(state, redirect_uri) do
    case Credentials.fetch() do
      {:ok, %{client_id: client_id}} ->
        query =
          URI.encode_query(
            client_id: client_id,
            response_type: "code",
            redirect_uri: redirect_uri,
            scope: @scopes,
            state: state
          )

        @authorize_url <> "?" <> query

      {:error, :not_configured} = err ->
        err
    end
  end

  @doc """
  Exchanges an authorization `code` for host access + refresh tokens.

  `redirect_uri` must match the one used in `authorize_url/2`.

  ## Returns

    * `{:ok, %{access_token: String.t(), refresh_token: String.t(), expires_at: DateTime.t()}}`
    * `{:error, :not_configured}` — credentials absent.
    * `{:error, term()}` — exchange failed.
  """
  @spec exchange_code(String.t(), String.t()) ::
          {:ok, %{access_token: String.t(), refresh_token: String.t(), expires_at: DateTime.t()}}
          | {:error, term()}
  def exchange_code(code, redirect_uri) do
    with {:ok, creds} <- Credentials.fetch() do
      @token_url
      |> Req.post(
        form: [
          grant_type: "authorization_code",
          code: code,
          redirect_uri: redirect_uri
        ],
        auth: basic_auth(creds),
        receive_timeout: @receive_timeout
      )
      |> handle_exchange_response()
    end
  end

  @doc """
  Refreshes a host access token using a stored `refresh_token`.

  Spotify may or may not return a new refresh token; this function returns only
  the new access token and its expiry — keep using the existing refresh token
  unless you persist a returned one yourself.

  ## Returns

    * `{:ok, %{access_token: String.t(), expires_at: DateTime.t()}}`
    * `{:error, :not_configured}` — credentials absent.
    * `{:error, term()}` — refresh failed.
  """
  @spec refresh(String.t()) ::
          {:ok, %{access_token: String.t(), expires_at: DateTime.t()}} | {:error, term()}
  def refresh(refresh_token) do
    with {:ok, creds} <- Credentials.fetch() do
      @token_url
      |> Req.post(
        form: [grant_type: "refresh_token", refresh_token: refresh_token],
        auth: basic_auth(creds),
        receive_timeout: @receive_timeout
      )
      |> handle_refresh_response()
    end
  end

  @doc """
  Checks whether the account behind `access_token` is Spotify Premium.

  Calls `GET /v1/me` and compares `product == "premium"`.

  ## Returns

    * `{:ok, true}` / `{:ok, false}`
    * `{:error, term()}` on transport or non-2xx responses.
  """
  @spec premium?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def premium?(access_token) do
    @me_url
    |> Req.get(auth: {:bearer, access_token}, receive_timeout: @receive_timeout)
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"product" => product}}} ->
        {:ok, product == "premium"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp basic_auth(%{client_id: id, client_secret: secret}), do: {:basic, "#{id}:#{secret}"}

  defp handle_exchange_response({:ok, %Req.Response{status: 200, body: body}})
       when is_map(body) do
    case body do
      %{"access_token" => access, "refresh_token" => refresh, "expires_in" => expires_in} ->
        {:ok,
         %{
           access_token: access,
           refresh_token: refresh,
           expires_at: expires_at(expires_in)
         }}

      _ ->
        {:error, {:unexpected_token_body, body}}
    end
  end

  defp handle_exchange_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_exchange_response({:error, reason}), do: {:error, reason}

  defp handle_refresh_response({:ok, %Req.Response{status: 200, body: body}})
       when is_map(body) do
    case body do
      %{"access_token" => access, "expires_in" => expires_in} ->
        {:ok, %{access_token: access, expires_at: expires_at(expires_in)}}

      _ ->
        {:error, {:unexpected_token_body, body}}
    end
  end

  defp handle_refresh_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_refresh_response({:error, reason}), do: {:error, reason}

  defp expires_at(expires_in) when is_integer(expires_in) do
    DateTime.utc_now() |> DateTime.add(expires_in, :second)
  end
end
