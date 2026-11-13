defmodule WhoseJam.Music.MockTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Music
  alias WhoseJam.Music.Providers.Mock

  test "has a small fixed catalog of valid tracks" do
    tracks = Mock.tracks()

    assert length(tracks) in 5..16
    assert Enum.all?(tracks, &Mock.valid_uri?(&1.uri))
    assert tracks |> Enum.map(& &1.uri) |> Enum.uniq() |> length() == length(tracks)
  end

  test "every track has its own placeholder cover, a file this app serves" do
    covers = Enum.map(Mock.tracks(), & &1.album_art_url)

    assert Enum.all?(covers, &Mock.valid_art_url?/1)
    assert Enum.uniq(covers) == covers

    for "/" <> path <- covers do
      assert File.exists?(Path.join([:code.priv_dir(:whose_jam), "static", path])),
             "no cover at priv/static/#{path}"
    end
  end

  test "accepts only its own covers as art" do
    refute Mock.valid_art_url?("https://example.com/images/mock/001.svg")
    refute Mock.valid_art_url?("//example.com/images/mock/001.svg")
    refute Mock.valid_art_url?("/images/mock/../../secret.svg")
    refute Mock.valid_art_url?("/images/mock/001.svg?x=1")
    refute Mock.valid_art_url?(nil)
  end

  test "search matches name or artist, case-insensitively, ignoring extra spaces" do
    assert {:ok, [%{name: "Neon Overdrive"}]} = Music.search(:mock, "neon over", %{})
    assert {:ok, [%{name: "Neon Overdrive"}]} = Music.search(:mock, "  NEON    overdrive ", %{})

    {:ok, by_artist} = Music.search(:mock, "LUCY MARLOWE", %{})
    assert by_artist != [] and Enum.all?(by_artist, &(&1.artist == "Lucy Marlowe"))

    assert Music.search(:mock, "zzzz nothing", %{}) == {:ok, []}
  end

  test "needs no connection step and is always eligible" do
    assert Mock.connect_kind() == :none
    assert {:ok, auth} = Mock.connect(%{})
    assert Mock.eligible?(auth)
  end

  test "tells the browser stub how long a song lasts" do
    assert Mock.client_config(%{}).track_ms > 0
  end

  test "tells the browser where each real song's audio is, and only theirs" do
    audio = Mock.client_config(%{}).audio
    real = for {id, _file} <- Mock.ncs_tracks(), do: "mock:track:" <> id

    assert audio |> Map.keys() |> Enum.sort() == Enum.sort(real)
    assert real != []

    for {uri, path} <- audio do
      assert Mock.valid_uri?(uri)
      assert Enum.any?(Mock.tracks(), &(&1.uri == uri))
      "mock:track:" <> id = uri
      assert path == "/audio/mock/#{id}.mp3"
    end
  end

  test "the real songs are searchable by their real names, any script" do
    assert {:ok, [%{name: "Anesthesia", artist: "Oxlo"}]} = Music.search(:mock, "anesthesia", %{})
    assert {:ok, [%{name: "デイドリーム (Daydream)"}]} = Music.search(:mock, "デイドリーム", %{})
  end
end
