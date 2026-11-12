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

  describe "redirect_host/1" do
    test "is 127.0.0.1 unless the provider asks for another loopback host" do
      # Spotify rejects `localhost`; YouTube's player rejects IP addresses.
      assert Music.redirect_host(Spotify) == "127.0.0.1"
      assert Music.redirect_host(WhoseJam.Music.Providers.Mock) == "127.0.0.1"
      assert Music.redirect_host(WhoseJam.Music.Providers.YouTube) == "localhost"
    end
  end

  describe "account questions and warnings" do
    test "a provider without them has no question, no warning and takes no answer" do
      for id <- [:spotify, :mock] do
        assert Music.account_question(id, %{}) == nil
        assert Music.warning(id, %{}) == nil
        assert Music.answer_account_question(id, %{}, true) == :error
      end
    end

    test "an unknown provider or a missing account has none either" do
      assert Music.account_question(:nope, %{}) == nil
      assert Music.account_question(nil, %{}) == nil
      assert Music.account_question(:youtube, nil) == nil
      assert Music.warning(:nope, %{}) == nil
      assert Music.warning(:youtube, nil) == nil
      assert Music.answer_account_question(:nope, %{}, true) == :error
    end
  end

  test "Spotify requires its OAuth redirect and refuses a malformed connect" do
    assert Spotify.connect_kind() == :oauth_redirect
    assert Spotify.connect(%{}) == {:error, :invalid_connect}
  end
end
