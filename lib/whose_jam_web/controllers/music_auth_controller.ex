defmodule WhoseJamWeb.MusicAuthController do
  @moduledoc """
  Host connect flow for `:oauth_redirect` music providers (Spotify today).

  `authorize/2` sends the host off to the provider with the room code and
  provider id signed into the `state` parameter; `callback/2` recovers them,
  hands the provider's `connect/1` the auth code, and stores the result on the
  game via `WhoseJam.Game.set_music/3`. Every failure branch redirects back to
  the host screen (or `/`) with a clear flash — never a crash page.

  Providers that authorize in the browser (`:browser`) or need no
  authorization (`:none`) never touch this controller; `HostLive` handles them.
  """
  use WhoseJamWeb, :controller

  alias WhoseJam.{Game, Music}

  @state_salt "music_oauth_state"
  @state_max_age 900

  # =========================================================================
  # /auth/:provider?code=ROOMCODE  — kick off the OAuth redirect
  # =========================================================================

  def authorize(conn, %{"provider" => provider_id, "code" => room_code})
      when is_binary(provider_id) and is_binary(room_code) do
    with {:ok, provider} <- redirect_provider(provider_id),
         :ok <- ensure_game(room_code),
         :ok <- ensure_configured(provider) do
      state = Phoenix.Token.sign(conn, @state_salt, %{room: room_code, provider: provider_id})

      case provider.authorize_url(state, redirect_uri(provider)) do
        {:ok, url} -> redirect(conn, external: url)
        {:error, _} -> failure(conn, :not_configured, provider, room_code)
      end
    else
      {:error, reason, provider} -> failure(conn, reason, provider, room_code)
    end
  end

  def authorize(conn, _params) do
    conn
    |> put_flash(:error, "Missing room code for the music connection.")
    |> redirect(to: ~p"/")
  end

  # =========================================================================
  # /auth/:provider/callback  — the provider redirects back here
  # =========================================================================

  # Host denied the authorization prompt.
  def callback(conn, %{"error" => _error, "state" => state} = params) do
    case recover_state(conn, params["provider"], state) do
      {:ok, room_code, provider} ->
        conn
        |> put_flash(:error, "#{provider.name()} connection was cancelled.")
        |> redirect(to: ~p"/host/#{room_code}")

      :error ->
        conn
        |> put_flash(:error, "The music connection was cancelled.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, %{"code" => auth_code, "state" => state} = params) do
    case recover_state(conn, params["provider"], state) do
      {:ok, room_code, provider} ->
        finish_callback(conn, provider, room_code, auth_code)

      :error ->
        conn
        |> put_flash(:error, "The music connection could not be verified. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "The music service returned an unexpected response. Please try again.")
    |> redirect(to: ~p"/")
  end

  # =========================================================================
  # Internals
  # =========================================================================

  defp finish_callback(conn, provider, room_code, auth_code) do
    params = %{"code" => auth_code, "redirect_uri" => redirect_uri(provider)}

    with {:ok, auth} <- provider.connect(params),
         :ok <- Game.set_music(room_code, provider.id(), auth) do
      conn
      |> put_connected_flash(provider, provider.eligible?(auth))
      |> redirect(to: ~p"/host/#{room_code}")
    else
      {:error, reason} -> failure(conn, reason, provider, room_code)
    end
  end

  defp put_connected_flash(conn, provider, true) do
    put_flash(conn, :info, "#{provider.name()} connected — you're ready to host playback.")
  end

  defp put_connected_flash(conn, provider, false) do
    put_flash(conn, :error, provider.ineligible_message())
  end

  defp redirect_provider(provider_id) do
    case Music.fetch_provider(provider_id) do
      {:ok, provider} ->
        if provider.connect_kind() == :oauth_redirect,
          do: {:ok, provider},
          else: {:error, :not_redirect, provider}

      :error ->
        {:error, :unknown_provider, nil}
    end
  end

  defp ensure_game(room_code) do
    if Game.exists?(room_code), do: :ok, else: {:error, :no_game, nil}
  end

  defp ensure_configured(provider) do
    if provider.configured?(), do: :ok, else: {:error, :not_configured, provider}
  end

  defp failure(conn, reason, provider, room_code) do
    {message, to} = failure_message(reason, provider, room_code)

    conn
    |> put_flash(:error, message)
    |> redirect(to: to)
  end

  defp failure_message(:no_game, _provider, _room), do: {"That game no longer exists.", ~p"/"}

  defp failure_message(:unknown_provider, _provider, _room),
    do: {"Unknown music service.", ~p"/"}

  defp failure_message(:not_redirect, provider, room),
    do: {"#{provider.name()} doesn't connect this way.", ~p"/host/#{room}"}

  defp failure_message(:not_configured, provider, room),
    do: {"#{provider.name()} isn't configured on the server.", ~p"/host/#{room}"}

  defp failure_message(:not_lobby, _provider, room),
    do: {"The game has started — you can't switch music service now.", ~p"/host/#{room}"}

  defp failure_message(_reason, provider, room),
    do:
      {"Couldn't complete the #{provider.name()} connection. Please try again.",
       ~p"/host/#{room}"}

  # Spotify rejects `localhost` and any non-HTTPS non-loopback redirect URI, so
  # we can't derive this from PHX_HOST (which is a LAN IP at a real party).
  # The OAuth round-trip only happens in the host's browser on the machine
  # running the server, so a loopback URI always works: default to
  # http://127.0.0.1:<public port>. Override per provider with
  # `config :whose_jam, :<id>_redirect_uri` (runtime.exs sets
  # :spotify_redirect_uri from SPOTIFY_REDIRECT_URI, e.g. an https URI when
  # deployed behind TLS). Must exactly match — including port — a redirect URI
  # registered with the provider.
  defp redirect_uri(provider) do
    Application.get_env(:whose_jam, :"#{provider.id()}_redirect_uri") ||
      "http://127.0.0.1:#{public_port()}/auth/#{provider.id()}/callback"
  end

  defp public_port do
    endpoint_config = WhoseJamWeb.Endpoint.config(:url) || []
    endpoint_config[:port] || WhoseJamWeb.Endpoint.config(:http)[:port] || 4000
  end

  # The state must verify, and its provider must be the one in the callback path.
  defp recover_state(conn, path_provider, state) do
    with {:ok, %{room: room_code, provider: provider_id}} <-
           Phoenix.Token.verify(conn, @state_salt, state, max_age: @state_max_age),
         true <- provider_id == path_provider,
         {:ok, provider} <- Music.fetch_provider(provider_id) do
      {:ok, room_code, provider}
    else
      _ -> :error
    end
  end
end
