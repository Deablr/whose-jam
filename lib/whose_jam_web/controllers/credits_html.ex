defmodule WhoseJamWeb.CreditsHTML do
  @moduledoc """
  Renders the credits page (`credits_html/index.html.heex`).
  """
  use WhoseJamWeb, :html

  embed_templates "credits_html/*"
end
