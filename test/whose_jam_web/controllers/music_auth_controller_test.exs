defmodule WhoseJamWeb.MusicAuthControllerTest do
  @moduledoc """
  The OAuth connect flow's guard rails — signed state, provider binding and the
  safe-redirect failure branches — with no provider API involved: every case
  here is rejected (or cancelled) before any token exchange.
  """
  use WhoseJamWeb.ConnCase, async: true

  @salt "music_oauth_state"

  defp state(room, provider, opts \\ []) do
    Phoenix.Token.sign(WhoseJamWeb.Endpoint, @salt, %{room: room, provider: provider}, opts)
  end

  describe "GET /auth/:provider" do
    test "an unknown service goes home with a flash", %{conn: conn} do
      conn = get(conn, "/auth/nope?code=ABCD")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Unknown music service."
    end

    test "a service that doesn't use a redirect says so and returns to the host screen",
         %{conn: conn} do
      conn = get(conn, "/auth/mock?code=ABCD")
      assert redirected_to(conn) == "/host/ABCD"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "doesn't connect this way"
    end

    test "a game that doesn't exist goes home", %{conn: conn} do
      conn = get(conn, "/auth/spotify?code=NOPE")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That game no longer exists."
    end

    test "a missing or malformed room code is a flash, not a crash", %{conn: conn} do
      for path <- ["/auth/mock", "/auth/mock?code[a]=b", "/auth/mock?code[]=x"] do
        conn = get(conn, path)
        assert redirected_to(conn) == "/", "expected #{path} to redirect home"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing room code"
      end
    end
  end

  describe "GET /auth/:provider/callback" do
    test "a denied prompt returns the host to their screen", %{conn: conn} do
      conn =
        get(conn, "/auth/spotify/callback?error=access_denied&state=#{state("ABCD", "spotify")}")

      assert redirected_to(conn) == "/host/ABCD"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Spotify connection was cancelled."
    end

    test "garbage state is rejected", %{conn: conn} do
      conn = get(conn, "/auth/spotify/callback?code=c&state=garbage")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be verified"
    end

    test "a state signed for one service is rejected at another's callback", %{conn: conn} do
      conn = get(conn, "/auth/mock/callback?code=c&state=#{state("ABCD", "spotify")}")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be verified"
    end

    test "a state signed with a different salt is rejected", %{conn: conn} do
      forged =
        Phoenix.Token.sign(WhoseJamWeb.Endpoint, "something else", %{
          room: "ABCD",
          provider: "spotify"
        })

      conn = get(conn, "/auth/spotify/callback?code=c&state=#{forged}")
      assert redirected_to(conn) == "/"
    end

    test "a state is accepted until max_age (900s) and rejected after", %{conn: conn} do
      # `signed_at` is in seconds. The fresh one is the control: it proves age,
      # not the token's shape, is what rejects the stale one.
      fresh = state("ABCD", "spotify", signed_at: System.system_time(:second) - 800)
      stale = state("ABCD", "spotify", signed_at: System.system_time(:second) - 1_000)

      conn1 = get(conn, "/auth/spotify/callback?error=access_denied&state=#{fresh}")
      assert redirected_to(conn1) == "/host/ABCD"

      conn2 = get(build_conn(), "/auth/spotify/callback?error=access_denied&state=#{stale}")
      assert redirected_to(conn2) == "/"
    end

    test "non-string state or code is a flash, not a crash", %{conn: conn} do
      valid = state("ABCD", "spotify")

      for query <- [
            "code=c&state[a]=b",
            "code=c&state[]=x",
            "error=x&state[a]=b",
            "code[a]=b&state=#{valid}"
          ] do
        conn = get(conn, "/auth/spotify/callback?" <> query)
        assert redirected_to(conn) == "/", "expected #{query} to redirect home"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "unexpected response"
      end
    end

    test "a callback with neither code nor error is an unexpected-response flash", %{conn: conn} do
      conn = get(conn, "/auth/spotify/callback")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "unexpected response"
    end
  end
end
