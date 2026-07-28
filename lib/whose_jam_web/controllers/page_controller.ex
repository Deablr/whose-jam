defmodule WhoseJamWeb.PageController do
  use WhoseJamWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
