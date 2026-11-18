defmodule WhoseJamWeb.CreditsControllerTest do
  use WhoseJamWeb.ConnCase, async: true

  describe "GET /credits" do
    test "lists the originator, tech lead and every QA tester", %{conn: conn} do
      html = conn |> get("/credits") |> html_response(200)

      assert html =~ "Credits"
      assert html =~ "Sierra Cordell"
      assert html =~ "Jared Dean"

      for name <- ["Zack Kreider", "Kyle Barker", "Aaron Stirewalt", "Sam Worley"] do
        assert html =~ name
      end
    end

    test "carries the AI disclosure", %{conn: conn} do
      html = conn |> get("/credits") |> html_response(200)

      assert html =~ "AI disclosure"
      assert html =~ "Anthropic’s Opus and Claude models"
      assert html =~ "OpenAI’s Sol model"
      assert html =~ "OpenAI image generation model, rebuilt by Opus as an SVG"
    end

    test "links back to the start", %{conn: conn} do
      html = conn |> get("/credits") |> html_response(200)
      assert html =~ ~s(href="/")
    end
  end
end
