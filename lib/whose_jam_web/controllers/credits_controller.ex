defmodule WhoseJamWeb.CreditsController do
  @moduledoc """
  The credits page: who made the game, who tested it, and how AI was used
  to build it. Static, so a plain controller rather than a LiveView.
  """
  use WhoseJamWeb, :controller

  def index(conn, _params) do
    render(conn, :index, page_title: "Credits")
  end
end
