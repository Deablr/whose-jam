defmodule WhoseJamWeb.PlayerSessionController do
  @moduledoc "Sets the signed device-token cookie binding a device to {game, player, role}. Stub — implemented in wave 3."
  use WhoseJamWeb, :controller

  def claim(conn, _params) do
    redirect(conn, to: ~p"/")
  end
end
