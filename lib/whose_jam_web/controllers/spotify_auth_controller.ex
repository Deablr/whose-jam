defmodule WhoseJamWeb.SpotifyAuthController do
  @moduledoc """
  Host Spotify OAuth (Authorization Code flow).

  `authorize/2` sends the host off to Spotify with the room code signed into the
  `state` parameter; `callback/2` recovers that room code, exchanges the auth
  code for tokens, checks Premium, and stores the result on the game via
  `WhoseJam.Game.set_spotify/2`. Every failure branch redirects back to the host
  screen (or `/`) with a clear flash — never a crash page.
  """
  use WhoseJamWeb, :controller

  alias WhoseJam.Game
  alias WhoseJam.Spotify.Auth
  alias WhoseJam.Spotify.Credentials

  @state_salt "spotify_oauth_state"
  @state_max_age 900

  # =========================================================================
  # /auth/spotify?code=ROOMCODE  — kick off the OAuth redirect
  # =========================================================================

  def authorize(conn, %{"code" => room_code}) do
    cond do
      not Game.exists?(room_code) ->
        conn
        |> put_flash(:error, "That game no longer exists.")
        |> redirect(to: ~p"/")

      not Credentials.configured?() ->
        conn
        |> put_flash(
          :error,
          "Spotify isn't configured on the server (missing SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET)."
        )
        |> redirect(to: ~p"/host/#{room_code}")

      true ->
        state = Phoenix.Token.sign(conn, @state_salt, room_code)
        redirect_uri = url(~p"/auth/spotify/callback")

        case Auth.authorize_url(state, redirect_uri) do
          {:error, :not_configured} ->
            conn
            |> put_flash(:error, "Spotify isn't configured on the server.")
            |> redirect(to: ~p"/host/#{room_code}")

          authorize_url when is_binary(authorize_url) ->
            redirect(conn, external: authorize_url)
        end
    end
  end

  def authorize(conn, _params) do
    conn
    |> put_flash(:error, "Missing room code for Spotify connection.")
    |> redirect(to: ~p"/")
  end

  # =========================================================================
  # /auth/spotify/callback  — Spotify redirects back here
  # =========================================================================

  # Host denied the authorization prompt.
  def callback(conn, %{"error" => _error, "state" => state}) do
    case recover_code(conn, state) do
      {:ok, room_code} ->
        conn
        |> put_flash(:error, "Spotify connection was cancelled.")
        |> redirect(to: ~p"/host/#{room_code}")

      :error ->
        conn
        |> put_flash(:error, "Spotify connection was cancelled.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, %{"code" => auth_code, "state" => state}) do
    case recover_code(conn, state) do
      {:ok, room_code} ->
        finish_callback(conn, room_code, auth_code)

      :error ->
        conn
        |> put_flash(:error, "Spotify connection could not be verified. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Spotify returned an unexpected response. Please try again.")
    |> redirect(to: ~p"/")
  end

  # =========================================================================
  # Internals
  # =========================================================================

  defp finish_callback(conn, room_code, auth_code) do
    redirect_uri = url(~p"/auth/spotify/callback")

    with {:ok, tokens} <- Auth.exchange_code(auth_code, redirect_uri),
         {:ok, premium?} <- Auth.premium?(tokens.access_token) do
      spotify = %{
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        expires_at: tokens.expires_at,
        premium?: premium?
      }

      Game.set_spotify(room_code, spotify)

      conn
      |> put_spotify_flash(premium?)
      |> redirect(to: ~p"/host/#{room_code}")
    else
      {:error, :not_configured} ->
        conn
        |> put_flash(:error, "Spotify isn't configured on the server.")
        |> redirect(to: ~p"/host/#{room_code}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Couldn't complete the Spotify connection. Please try again.")
        |> redirect(to: ~p"/host/#{room_code}")
    end
  end

  defp put_spotify_flash(conn, true) do
    put_flash(conn, :info, "Spotify Premium connected — you're ready to host playback.")
  end

  defp put_spotify_flash(conn, false) do
    put_flash(
      conn,
      :error,
      "That Spotify account isn't Premium — you can't host playback. Connect a Premium account to start the game."
    )
  end

  defp recover_code(conn, state) do
    case Phoenix.Token.verify(conn, @state_salt, state, max_age: @state_max_age) do
      {:ok, room_code} -> {:ok, room_code}
      {:error, _reason} -> :error
    end
  end
end
