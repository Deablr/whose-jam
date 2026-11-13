defmodule WhoseJamWeb.PlayerSessionController do
  @moduledoc """
  Persists the device→player binding in the signed session cookie.

  `PlayLive` cannot set cookies from inside the LiveView socket, so it signs a
  `WhoseJamWeb.PlayerToken` carrying `{code, player_id, role}` and does a full
  navigation to `/claim/:token`. This controller verifies the token, stores it
  in the session, and bounces the device back to `/play/:code`, where
  `PlayLive.mount/3` silently rejoins from that same token.
  """
  use WhoseJamWeb, :controller

  alias WhoseJamWeb.PlayerToken

  def claim(conn, %{"token" => token}) do
    case PlayerToken.verify(token) do
      {:ok, %{code: code}} ->
        conn
        |> put_session(:player_token, token)
        |> redirect(to: ~p"/play/#{code}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That join link expired — please join again.")
        |> redirect(to: ~p"/")
    end
  end
end
