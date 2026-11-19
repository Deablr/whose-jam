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

    def playlist_authorize_url(state, redirect_uri) do
      {:ok,
       "https://stub.example/playlist?" <>
         URI.encode_query(state: state, redirect_uri: redirect_uri)}
    end

    # The "code" decides the outcome; the link says what the playlist got.
    def save_playlist(%{"code" => "good", "redirect_uri" => _uri}, name, uris),
      do: {:ok, "https://stub.example/list?" <> URI.encode_query(name: name, n: length(uris))}

    def save_playlist(%{"code" => "plain"}, _name, _uris), do: {:ok, "http://stub.example/list"}
    def save_playlist(_params, _name, _uris), do: {:error, :exchange_failed}
  end

  setup do
    previous = Application.fetch_env!(:whose_jam, :music_providers)
    Application.put_env(:whose_jam, :music_providers, [OauthStub | previous])
    on_exit(fn -> Application.put_env(:whose_jam, :music_providers, previous) end)

    # Straight to the picking: a round's how-to-play is the screens' business.
    previous_intro = Application.fetch_env(:whose_jam, :intro_ms)
    Application.put_env(:whose_jam, :intro_ms, 0)

    on_exit(fn ->
      case previous_intro do
        {:ok, ms} -> Application.put_env(:whose_jam, :intro_ms, ms)
        :error -> Application.delete_env(:whose_jam, :intro_ms)
      end
    end)

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

  # A stand-in host screen for `room`, with the game's host-screen grace cut to
  # 100ms, and this test subscribed to the room. Close it with
  # `close_host_screen/1`.
  defp open_host_screen(room) do
    previous = Application.fetch_env(:whose_jam, :host_grace_ms)
    Application.put_env(:whose_jam, :host_grace_ms, 100)

    on_exit(fn ->
      case previous do
        {:ok, ms} -> Application.put_env(:whose_jam, :host_grace_ms, ms)
        :error -> Application.delete_env(:whose_jam, :host_grace_ms)
      end
    end)

    host = start_supervised!({Agent, fn -> nil end})
    :ok = Game.attach_host(room, host)
    Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> room)
  end

  # Closes the stand-in host screen and waits for the game to see it. In a
  # browser the screen stays connected until the provider's page loads, so it
  # goes after /auth/:provider; closing it before is the fallback order, for a
  # screen whose connection dropped just before the click.
  defp close_host_screen(room) do
    stop_supervised!(Agent)
    [{game, _}] = Registry.lookup(WhoseJam.Game.Registry, room)
    _ = :sys.get_state(game)
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
  # The callback ends the sign-in, so a host screen that then never comes back
  # still ends the game.
  test "leaving to sign in doesn't end the game; the callback ends the sign-in",
       %{conn: conn, room: room} do
    open_host_screen(room)

    # As in a browser: /auth while the host screen is still connected.
    state = authorize(conn, room)
    close_host_screen(room)
    refute_receive {:game_ended, _}, 300

    conn = get(build_conn(), "/auth/oauth_stub/callback?code=good&state=#{state}")
    assert redirected_to(conn) == "/host/#{room}"
    assert_receive {:game_state, %{music: %{id: :oauth_stub, eligible?: true}}}
    assert_receive {:game_ended, :host_left}, 1000
  end

  test "a cancelled sign-in is over too", %{conn: conn, room: room} do
    open_host_screen(room)

    # The fallback order: the host screen dropped just before /auth.
    close_host_screen(room)
    state = authorize(conn, room)
    refute_receive {:game_ended, _}, 300

    conn = get(build_conn(), "/auth/oauth_stub/callback?error=access_denied&state=#{state}")
    assert redirected_to(conn) == "/host/#{room}"
    assert_receive {:game_ended, :host_left}, 1000
  end

  # Anyone with the room code can get a signed state from /auth, but a notice
  # the game refused gives no sign-in for its callback to end.
  test "a callback for a sign-in the game refused can't end the host's",
       %{conn: conn, room: room} do
    open_host_screen(room)

    host_state = authorize(conn, room)
    close_host_screen(room)
    # Past the usual grace, the game waits on the host's sign-in alone.
    refute_receive {:game_ended, _}, 250

    guest_state = authorize(build_conn(), room)
    get(build_conn(), "/auth/oauth_stub/callback?error=access_denied&state=#{guest_state}")
    refute_receive {:game_ended, _}, 300

    # The host's own callback does end it.
    get(build_conn(), "/auth/oauth_stub/callback?error=access_denied&state=#{host_state}")
    assert_receive {:game_ended, :host_left}, 1000
  end

  describe "saving the night's playlist" do
    # Plays a two-player game on the stub to its end: each voter calls it.
    defp finished_game(room) do
      :ok = Game.set_config(room, %{min_players: 2, answer_s_per_question: 5})
      ids = for i <- 1..2, do: elem(Game.join(room, "P#{i}"), 1).player_id
      :ok = Game.set_music(room, :oauth_stub, %{eligible?: true})
      :ok = Game.start_game(room)
      Phoenix.PubSub.subscribe(WhoseJam.PubSub, "game:" <> room)

      for id <- ids, q <- Game.player_view(room, id).me.assigned do
        song = %{uri: "stub:#{id}", name: id, artist: "A", album_art_url: nil}
        :ok = Game.submit_song(room, id, q.question_id, song)
      end

      play_out(room, ids)
    end

    defp play_out(room, ids) do
      receive do
        {:game_state, %{phase: :finished} = view} ->
          view

        {:game_state, %{phase: :playing, round_state: :revealing}} ->
          Game.song_ended(room)
          play_out(room, ids)

        {:game_state, %{phase: :playing, round_state: :voting} = view} ->
          picker = view.round.song.name

          for id <- ids,
              id not in view.round.voters,
              do: Game.cast_vote(room, id, if(id == picker, do: hd(ids -- [id]), else: picker))

          play_out(room, ids)

        {:game_state, _view} ->
          play_out(room, ids)
      after
        10_000 -> flunk("the game never finished")
      end
    end

    defp authorize_playlist(conn, room) do
      url = conn |> get("/auth/oauth_stub?code=#{room}&for=playlist") |> redirected_to(302)
      assert url =~ "https://stub.example/playlist?"
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["redirect_uri"] =~ "/auth/oauth_stub/callback"
      query["state"]
    end

    test "a finished game's songs are saved, and every screen gets the link",
         %{conn: conn, room: room} do
      final = finished_game(room)
      assert final.saved_playlist == nil

      state = authorize_playlist(conn, room)
      conn = get(build_conn(), "/auth/oauth_stub/callback?code=good&state=#{state}")

      assert redirected_to(conn) == "/host/#{room}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "saved to OauthStub"

      link = Game.get_state(room).saved_playlist
      assert link =~ "https://stub.example/list?"
      assert URI.decode_query(URI.parse(link).query)["n"] == "#{length(final.playlist)}"
      # The connection the game plays with is untouched.
      assert Game.host_state(room).music_auth == %{eligible?: true}
    end

    test "a failed or cancelled save, or one that returns no https link, saves nothing",
         %{conn: conn, room: room} do
      finished_game(room)

      for code <- ["boom", "plain"] do
        state = authorize_playlist(conn, room)
        conn = get(build_conn(), "/auth/oauth_stub/callback?code=#{code}&state=#{state}")
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Couldn’t save the playlist"
      end

      state = authorize_playlist(conn, room)
      conn = get(build_conn(), "/auth/oauth_stub/callback?error=access_denied&state=#{state}")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Saving the playlist"
      assert Game.get_state(room).saved_playlist == nil
    end

    test "a game still being played has no playlist to save", %{conn: conn, room: room} do
      :ok = Game.set_music(room, :oauth_stub, %{eligible?: true})
      conn = get(conn, "/auth/oauth_stub?code=#{room}&for=playlist")

      # Refused before the sign-in: nobody grants a scope for nothing.
      assert redirected_to(conn) == "/host/#{room}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "once the game is over"
      assert Game.get_state(room).saved_playlist == nil
    end

    test "once saved, it stays saved: another sign-in is refused", %{conn: conn, room: room} do
      finished_game(room)
      state = authorize_playlist(conn, room)
      get(build_conn(), "/auth/oauth_stub/callback?code=good&state=#{state}")
      link = Game.get_state(room).saved_playlist
      assert link

      conn = get(build_conn(), "/auth/oauth_stub?code=#{room}&for=playlist")
      assert redirected_to(conn) == "/host/#{room}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already saved"
      assert Game.get_state(room).saved_playlist == link
    end

    test "a service that can't save playlists says so", %{conn: conn, room: room} do
      conn = get(conn, "/auth/spotify?code=#{room}&for=playlist")
      # Spotify can, but isn't configured here; Mock doesn't sign in at all.
      assert redirected_to(conn) == "/host/#{room}"

      conn = get(build_conn(), "/auth/mock?code=#{room}&for=playlist")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "doesn't connect this way"
    end
  end
end
