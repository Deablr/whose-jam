defmodule WhoseJam.MusicTest do
  use ExUnit.Case, async: true

  alias WhoseJam.Music
  alias WhoseJam.Music.Providers.Spotify

  describe "refresh_if_due/2" do
    defmodule Refreshing do
      def refresh(%{refresh_token: "good"}) do
        {:ok, %{access_token: "new", expires_at: DateTime.add(DateTime.utc_now(), 3600)}}
      end

      def refresh(_auth), do: {:error, :nope}
    end

    test "leaves credentials alone while they are fresh" do
      auth = %{
        access_token: "old",
        refresh_token: "good",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      }

      assert Music.refresh_if_due(Refreshing, auth) == {auth, false}
    end

    test "refreshes and merges credentials that are about to expire" do
      auth = %{
        access_token: "old",
        refresh_token: "good",
        expires_at: DateTime.add(DateTime.utc_now(), 10)
      }

      {fresh, changed?} = Music.refresh_if_due(Refreshing, auth)
      assert changed?
      assert fresh.access_token == "new"
      assert fresh.refresh_token == "good"
    end

    test "keeps the old credentials when the refresh fails" do
      auth = %{
        access_token: "old",
        refresh_token: "bad",
        expires_at: DateTime.add(DateTime.utc_now(), -10)
      }

      assert Music.refresh_if_due(Refreshing, auth) == {auth, false}
    end

    test "never refreshes credentials that don't expire, or providers that can't refresh" do
      assert Music.refresh_if_due(Refreshing, %{}) == {%{}, false}

      expiring = %{expires_at: DateTime.add(DateTime.utc_now(), -10)}
      assert Music.refresh_if_due(WhoseJam.Music.Providers.Mock, expiring) == {expiring, false}
    end
  end

  describe "refresh_delay_ms/1" do
    test "is nil when the credentials never expire" do
      assert Music.refresh_delay_ms(%{}) == nil
    end

    test "fires a minute before expiry, but never faster than the floor" do
      far = %{expires_at: DateTime.add(DateTime.utc_now(), 3600)}
      assert_in_delta Music.refresh_delay_ms(far), 3_540_000, 2_000

      soon = %{expires_at: DateTime.add(DateTime.utc_now(), 5)}
      assert Music.refresh_delay_ms(soon) == 30_000
    end
  end

  describe "playback_error_message/2" do
    test "uses the provider's wording when it has some" do
      assert Music.playback_error_message(:spotify, %{"reason" => "account_error"}) =~ "Premium"
    end

    test "falls back to a generic message" do
      assert Music.playback_error_message(:spotify, %{"reason" => "???"}) =~ "unavailable"
      assert Music.playback_error_message(:mock, %{"reason" => "x"}) =~ "unavailable"
      assert Music.playback_error_message(nil, %{}) =~ "unavailable"
    end
  end

  test "Spotify requires its OAuth redirect and refuses a malformed connect" do
    assert Spotify.connect_kind() == :oauth_redirect
    assert Spotify.connect(%{}) == {:error, :invalid_connect}
  end
end
