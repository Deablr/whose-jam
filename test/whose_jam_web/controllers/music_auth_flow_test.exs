defmodule WhoseJamWeb.MusicAuthFlowTest do
  @moduledoc """
  The OAuth connect flow end to end — authorize redirect, signed-state
  round-trip, and the callback storing the host's auth on the game — using a
  stub `:oauth_redirect` provider, so no real provider API is involved.

  Not async: it swaps the enabled-provider list, which is global.
  """
  use WhoseJamWeb.ConnCase, async: false

  alias WhoseJam.Game
  alias WhoseJam.Content.{Question, Theme}
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
end
