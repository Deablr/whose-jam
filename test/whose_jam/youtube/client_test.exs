defmodule WhoseJam.YouTube.ClientTest do
  @moduledoc """
  The pure halves of the YouTube Data API client: mapping a `search.list`
  response to tracks, and recognizing a used-up quota. The request itself is
  manual-playtest only.
  """
  use ExUnit.Case, async: true

  alias WhoseJam.Music
  alias WhoseJam.YouTube.Client

  defp item(id, title, channel, thumbnails \\ nil) do
    %{
      "kind" => "youtube#searchResult",
      "id" => %{"kind" => "youtube#video", "videoId" => id},
      "snippet" => %{
        "title" => title,
        "channelTitle" => channel,
        "thumbnails" =>
          thumbnails ||
            %{
              "default" => %{"url" => "https://i.ytimg.com/vi/#{id}/default.jpg"},
              "medium" => %{"url" => "https://i.ytimg.com/vi/#{id}/mqdefault.jpg"},
              "high" => %{"url" => "https://i.ytimg.com/vi/#{id}/hqdefault.jpg"}
            }
      }
    }
  end

  defp error_body(reason) do
    %{
      "error" => %{
        "code" => 403,
        "errors" => [%{"domain" => "youtube.quota", "reason" => reason}]
      }
    }
  end

  describe "tracks_from_search/1" do
    test "maps a video to a provider-namespaced track with the largest thumbnail" do
      body = %{"items" => [item("dQw4w9WgXcQ", "Never Gonna Give You Up", "Rick Astley")]}

      assert Client.tracks_from_search(body) == [
               %{
                 uri: "youtube:video:dQw4w9WgXcQ",
                 name: "Never Gonna Give You Up",
                 artist: "Rick Astley",
                 album_art_url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
               }
             ]
    end

    test "every track it produces is one the provider accepts back unchanged" do
      body = %{
        "items" => [
          item("dQw4w9WgXcQ", "Sweet Child O&#39; Mine", "Guns N&#39; Roses - Topic"),
          item("a-b_c-d_e-f", "Live", "Band", %{
            "high" => %{"url" => "https://i.ytimg.com/vi/a-b_c-d_e-f/hqdefault_live.jpg"}
          })
        ]
      }

      tracks = Client.tracks_from_search(body)
      assert length(tracks) == 2

      for track <- tracks do
        assert Music.normalize_track(:youtube, track) == {:ok, track}
      end
    end

    test "decodes the HTML entities the Data API puts in titles, once" do
      body = %{
        "items" => [
          item(
            "dQw4w9WgXcQ",
            "Tom &amp; Jerry &quot;Live&quot; &#39;99 &lt;3 &#x1F3B5; &amp;lt;",
            "AC&#47;DC"
          )
        ]
      }

      assert [track] = Client.tracks_from_search(body)
      assert track.name == ~s(Tom & Jerry "Live" '99 <3 🎵 &lt;)
      assert track.artist == "AC/DC"
    end

    test "leaves text that only looks like an entity alone" do
      title = "R&B; &nope; &#xD800; &#0; &#99999999; 100% &"
      body = %{"items" => [item("dQw4w9WgXcQ", title, "X")]}

      assert [track] = Client.tracks_from_search(body)
      assert track.name == title
    end

    test "drops the auto-generated \" - Topic\" suffix from artist channels only" do
      body = %{
        "items" => [
          item("dQw4w9WgXcQ", "Song", "Daft Punk - Topic"),
          item("a-b_c-d_e-f", "Song", "Topic - Daft Punk")
        ]
      }

      assert [%{artist: "Daft Punk"}, %{artist: "Topic - Daft Punk"}] =
               Client.tracks_from_search(body)
    end

    test "falls back to smaller thumbnails, then to none" do
      medium = %{"medium" => %{"url" => "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"}}

      assert [%{album_art_url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"}] =
               Client.tracks_from_search(%{"items" => [item("dQw4w9WgXcQ", "S", "A", medium)]})

      assert [%{album_art_url: nil}] =
               Client.tracks_from_search(%{"items" => [item("dQw4w9WgXcQ", "S", "A", %{})]})
    end

    test "skips results that aren't a well-formed video" do
      body = %{
        "items" => [
          %{"id" => %{"kind" => "youtube#channel", "channelId" => "UC123"}, "snippet" => %{}},
          %{"id" => %{"videoId" => "too-short"}, "snippet" => %{"title" => "x"}},
          %{"id" => %{"videoId" => "dQw4w9WgXcQ\n"}, "snippet" => %{"title" => "x"}},
          %{"id" => %{"videoId" => 42}},
          "garbage",
          %{"id" => %{"videoId" => "dQw4w9WgXcQ"}}
        ]
      }

      assert Client.tracks_from_search(body) == [
               %{uri: "youtube:video:dQw4w9WgXcQ", name: "", artist: "", album_art_url: nil}
             ]
    end

    test "an empty or unexpected body is no results" do
      assert Client.tracks_from_search(%{"items" => []}) == []
      assert Client.tracks_from_search(%{}) == []
      assert Client.tracks_from_search(%{"items" => "nope"}) == []
    end
  end

  describe "quota_exceeded?/1" do
    test "recognizes Google's quota reasons" do
      for reason <- ~w(quotaExceeded dailyLimitExceeded rateLimitExceeded userRateLimitExceeded) do
        assert Client.quota_exceeded?(error_body(reason)), reason
      end
    end

    test "other failures are not a quota problem" do
      refute Client.quota_exceeded?(error_body("forbidden"))
      refute Client.quota_exceeded?(error_body("keyInvalid"))
      refute Client.quota_exceeded?(%{"error" => %{"errors" => ["quotaExceeded"]}})
      refute Client.quota_exceeded?(%{"error" => "quotaExceeded"})
      refute Client.quota_exceeded?("quotaExceeded")
      refute Client.quota_exceeded?(nil)
    end
  end
end
