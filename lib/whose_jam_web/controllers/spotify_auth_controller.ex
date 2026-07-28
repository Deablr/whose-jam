defmodule WhoseJamWeb.SpotifyAuthController do
  @moduledoc "Host Spotify OAuth: redirect to authorize, handle callback. Stub — implemented in wave 3."
  use WhoseJamWeb, :controller

  def authorize(conn, _params) do
    redirect(conn, to: ~p"/")
  end

  def callback(conn, _params) do
    redirect(conn, to: ~p"/")
  end
end
