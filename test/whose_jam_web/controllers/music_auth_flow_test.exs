defmodule WhoseJamWeb.MusicAuthFlowTest do
  @moduledoc """
  The OAuth connect flow end to end — authorize redirect, signed-state
  round-trip, and the callback storing the host's auth on the game — using a
  stub `:oauth_redirect` provider, so no real provider API is involved.

  Not async: it swaps the enabled-provider list, which is global.
  """
  use WhoseJamWeb.ConnCase, async: false

  alias WhoseJam.Content.{Question, Theme}
  alias WhoseJam.Game
  alias WhoseJam.Repo

  defmodule OauthStub do
    @behaviour WhoseJam.Music.Provider

    def id, do: :oauth_stub
    def name, do: "OauthStub"
    def requirement, do: "needs a stub account"
    def ineligible_message, do: "Stub account can't play."
    def connect_kind, do: :oauth_redirect
    def video?, do: false
    def configured?, do: true
    def search(_query, _auth), do: {:ok, []}
    def search_debounce_ms, do: 300
    def redirect_host, do: Process.get(:stub_redirect_host, "127.0.0.1")
    def valid_uri?(_uri), do: true
    def valid_art_url?(_url), do: false
    def eligible?(auth), do: auth.eligible?
    def client_config(_auth), do: %{}

    def authorize_url(state, redirect_uri) do
      {:ok,
       "https://stub.example/authorize?" <>
         URI.encode_query(state: state, redirect_uri: redirect_uri)}
    end

    # The "code" decides the outcome.
    def connect(%{"code" => "good", "redirect_uri" => uri}),
      do: {:ok, %{eligible?: true, uri: uri}}

    def connect(%{"code" => "free"}), do: {:ok, %{eligible?: false}}
    def connect(%{"code" => "boom"}), do: {:error, :exchange_failed}
  end

  setup do
    previous = Application.fetch_env!(:whose_jam, :music_providers)
    Application.put_env(:whose_jam, :music_providers, [OauthStub | previous])
    on_exit(fn -> Application.put_env(:whose_jam, :music_providers, previous) end)

    theme =
      %Theme{}
      |> Theme.changeset(%{
        name: "Theme #{System.unique_integer([:positive])}",
        description: "d",
        style_sequence: [:guess_who]
      })
      |> Repo.insert!()

    for i <- 1..8 do
      %Question{}
      |> Question.changeset(%{
        theme_id: theme.id,
        prompt: "q#{i}",
        style: :guess_who,
        is_example: false
      })
      |> Repo.insert!()
    end

    {:ok, code} = Game.create_game(theme.id, %{questions_per_player: 1})

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(WhoseJam.Game.Supervisor),
          do: DynamicSupervisor.terminate_child(WhoseJam.Game.Supervisor, pid)
    end)

    %{room: code}
  end

  # Runs /auth/oauth_stub and returns the signed `state` the provider would get back.
  defp authorize(conn, room) do
    conn = get(conn, "/auth/oauth_stub?code=#{room}")
    url = redirected_to(conn, 302)
    assert url =~ "https://stub.example/authorize?"
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["redirect_uri"] =~ "/auth/oauth_stub/callback"
    query["state"]
  end

  test "authorize signs a state that the callback accepts, and stores the host's auth",
       %{conn: conn, room: room} do
    state = authorize(conn, room)

    conn = get(build_conn(), "/auth/oauth_stub/callback?code=good&state=#{state}")

    assert redirected_to(conn) == "/host/#{room}"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "OauthStub connected"

    assert %{id: :oauth_stub, eligible?: true} = Game.get_state(room).music
    # The callback used the same redirect_uri the authorize step sent.
    assert Game.host_state(room).music_auth.uri =~ "/auth/oauth_stub/callback"
  end

  test "the redirect URI uses the provider's loopback host, at authorize and at callback",
       %{conn: conn, room: room} do
    Process.put(:stub_redirect_host, "localhost")

    url = conn |> get("/auth/oauth_stub?code=#{room}") |> redirected_to(302)
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert %URI{scheme: "http", host: "localhost", path: "/auth/oauth_stub/callback"} =
             URI.parse(query["redirect_uri"])

    conn = get(build_conn(), "/auth/oauth_stub/callback?code=good&state=#{query["state"]}")
    assert redirected_to(conn) == "/host/#{room}"
    assert Game.host_state(room).music_auth.uri == query["redirect_uri"]
  end

  describe "the shipped providers' default redirect" do
    @credential_vars ~w(SPOTIFY_CLIENT_ID SPOTIFY_CLIENT_SECRET YOUTUBE_API_KEY
                        YOUTUBE_CLIENT_ID YOUTUBE_CLIENT_SECRET)

    setup do
      previous = Map.new(@credential_vars, &{&1, System.get_env(&1)})
      Enum.each(@credential_vars, &System.put_env(&1, "test-value"))

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)
    end

    defp default_redirect_uri(conn, provider, room) do
      url = conn |> get("/auth/#{provider}?code=#{room}") |> redirected_to(302)
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      URI.parse(query["redirect_uri"])
    end

    # Serve the app's public URL as `url` for the rest of the test.
    defp serve_at(url) do
      previous = Application.fetch_env!(:whose_jam, WhoseJamWeb.Endpoint)
      configure_endpoint(Keyword.put(previous, :url, url))
      on_exit(fn -> configure_endpoint(previous) end)
    end

    defp configure_endpoint(config) do
      Application.put_env(:whose_jam, WhoseJamWeb.Endpoint, config)
      WhoseJamWeb.Endpoint.config_change([{WhoseJamWeb.Endpoint, config}], [])
    end

    # Spotify rejects `localhost`; YouTube's player rejects IP addresses, and the
    # host screen stays on the redirect's host.
    test "over http, is on 127.0.0.1 for Spotify and on localhost for YouTube",
         %{conn: conn, room: room} do
      assert %URI{scheme: "http", host: "127.0.0.1", path: "/auth/spotify/callback"} =
               default_redirect_uri(conn, "spotify", room)

      assert %URI{scheme: "http", host: "localhost", path: "/auth/youtube/callback"} =
               default_redirect_uri(conn, "youtube", room)
    end

    # At a party PHX_HOST is the laptop's LAN IP, which no provider accepts.
    test "over http, never uses the public host", %{conn: conn, room: room} do
      serve_at(scheme: "http", host: "192.168.1.23", port: 4000)

      assert %URI{host: "127.0.0.1", port: 4000} = default_redirect_uri(conn, "spotify", room)
      assert %URI{host: "localhost", port: 4000} = default_redirect_uri(conn, "youtube", room)
    end

    test "over https, is the app's own public URL", %{conn: conn, room: room} do
      serve_at(scheme: "https", host: "jam.example.com", port: 443)

      assert default_redirect_uri(conn, "spotify", room) ==
               URI.parse("https://jam.example.com/auth/spotify/callback")

      assert default_redirect_uri(conn, "youtube", room) ==
               URI.parse("https://jam.example.com/auth/youtube/callback")
    end

    test "over https on a non-standard port, keeps the port", %{conn: conn, room: room} do
      serve_at(scheme: "https", host: "jam.example.com", port: 8443)

      assert default_redirect_uri(conn, "youtube", room) ==
               URI.parse("https://jam.example.com:8443/auth/youtube/callback")
    end

    test "an explicit redirect URI wins over both defaults", %{conn: conn, room: room} do
      serve_at(scheme: "https", host: "jam.example.com", port: 443)
      Application.put_env(:whose_jam, :youtube_redirect_uri, "https://other.example/cb")
      on_exit(fn -> Application.delete_env(:whose_jam, :youtube_redirect_uri) end)

      assert default_redirect_uri(conn, "youtube", room) == URI.parse("https://other.example/cb")
    end
  end

  test "an ineligible account is stored but flashed as an error", %{conn: conn, room: room} do
    state = authorize(conn, room)

    conn = get(build_conn(), "/auth/oauth_stub/callback?code=free&state=#{state}")

    assert redirected_to(conn) == "/host/#{room}"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Stub account can't play."
    assert %{id: :oauth_stub, eligible?: false} = Game.get_state(room).music
  end

  test "a failed code exchange leaves the game unconnected", %{conn: conn, room: room} do
    state = authorize(conn, room)

    conn = get(build_conn(), "/auth/oauth_stub/callback?code=boom&state=#{state}")

    assert redirected_to(conn) == "/host/#{room}"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Couldn't complete the OauthStub connection"

    assert Game.get_state(room).music == nil
  end

  test "switching service after the game started is refused with a flash", %{
    conn: conn,
    room: room
  } do
    for i <- 1..3, do: Game.join(room, "P#{i}")
    :ok = Game.set_music(room, :mock, %{})
    :ok = Game.start_game(room)

    state = authorize(conn, room)
    conn = get(build_conn(), "/auth/oauth_stub/callback?code=good&state=#{state}")

    assert redirected_to(conn) == "/host/#{room}"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can't switch music service"
    assert Game.get_state(room).music.id == :mock
  end

  # Signing in takes the host screen away to the provider's page, which would
  # otherwise end the game once the (here shortened) host-screen grace ran out.
  test "leaving to sign in doesn't end the game", %{conn: conn, room: room} do
    previous = Application.fetch_env(:whose_jam, :host_grace_ms)
    Application.put_env(:whose_jam, :host_grace_ms, 50)

    on_exit(fn ->
      case previous do
        {:ok, ms} -> Application.put_env(:whose_jam, :host_grace_ms, ms)
        :error -> Application.delete_env(:whose_jam, :host_grace_ms)
      end
    end)

    host = start_supervised!({Agent, fn -> nil end})
    :ok = Game.attach_host(room, host)
    Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> room)

    state = authorize(conn, room)
    stop_supervised!(Agent)
    refute_receive {:game_ended, _}, 300

    conn = get(build_conn(), "/auth/oauth_stub/callback?code=good&state=#{state}")
    assert redirected_to(conn) == "/host/#{room}"
    assert %{id: :oauth_stub, eligible?: true} = Game.get_state(room).music
  end
end
