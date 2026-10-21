defmodule WhoseJam.Music.MockTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Music
  alias WhoseJam.Music.Providers.Mock

  test "has a small fixed catalog of valid, art-free tracks" do
    tracks = Mock.tracks()

    assert length(tracks) in 5..12
    assert Enum.all?(tracks, &Mock.valid_uri?(&1.uri))
    assert Enum.all?(tracks, &is_nil(&1.album_art_url))
    assert tracks |> Enum.map(& &1.uri) |> Enum.uniq() |> length() == length(tracks)
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
end
