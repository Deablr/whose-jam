defmodule WhoseJam.YouTube.Auth do
  @moduledoc """
  The host's Google sign-in for the YouTube provider (OAuth 2.0 Authorization
  Code flow).

  ## What it proves, and what it can't

  It proves the host signed in to a Google account in the browser that will
  play the songs. It asks only for the `openid` scope and keeps nothing: no
  tokens, and no name or email (the host screen is shown to the whole room,
  and anyone with the room code can open it). Nothing after the sign-in calls
  Google on the host's behalf — song search uses the server's API key, see
  `WhoseJam.YouTube.Client`.

  It cannot prove the account has **YouTube Premium**. No Google API or OAuth
  scope reports that, so the provider asks the host instead (see
  `WhoseJam.Music.Providers.YouTube`).

  ## Flow

    1. Redirect the host to `authorize_url/2`.
    2. Google redirects back to `redirect_uri` with `code` and `state`.
    3. `sign_in/2` exchanges the code. A successful exchange is the proof: Google
       only issues a code to a signed-in account that approved the request.

  Credentials are read from the environment at runtime; every function returns
  `{:error, :not_configured}` when they are absent.
  """

  alias WhoseJam.YouTube.Credentials

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"

  @scopes "openid"

  @doc """
  Builds the Google authorization URL to redirect the host to.

  `state` is the opaque CSRF token verified on the way back. `redirect_uri`
  must exactly match one registered on the OAuth client. The account chooser
  is always shown, so "Switch account" really can switch.
  """
  @spec authorize_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_configured}
  def authorize_url(state, redirect_uri) do
    with {:ok, %{client_id: client_id}} <- Credentials.fetch_oauth_client() do
      query =
        URI.encode_query(
          client_id: client_id,
          response_type: "code",
          redirect_uri: redirect_uri,
          scope: @scopes,
          state: state,
          prompt: "select_account"
        )

      {:ok, @authorize_url <> "?" <> query}
    end
  end

  @doc """
  Exchanges an authorization `code`, which proves the host signed in.

  ## Returns

    * `:ok` — Google accepted the code.
    * `{:error, :not_configured}` — credentials absent.
    * `{:error, term()}` — the exchange failed.
  """
  @spec sign_in(String.t(), String.t()) :: :ok | {:error, term()}
  def sign_in(code, redirect_uri) when is_binary(code) and is_binary(redirect_uri) do
    with {:ok, client} <- Credentials.fetch_oauth_client() do
      exchange_code(client, code, redirect_uri)
    end
  end

  defp exchange_code(client, code, redirect_uri) do
    @token_url
    |> Req.post(
      form: [
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: client.client_id,
        client_secret: client.client_secret
      ],
      receive_timeout: Credentials.receive_timeout()
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        :ok

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:unexpected_token_body, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
