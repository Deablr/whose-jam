defmodule WhoseJam.Music.YouTubeTest do
  @moduledoc """
  What is specific to the YouTube provider: a signed-in Google account is
  enough to host, Premium is asked rather than verified, and a missing
  "yes" produces a warning instead of blocking the game. No network: the
  sign-in itself and the Data API are manual-playtest only.

  Not async: the credential tests change OS environment variables.
  """
  use ExUnit.Case, async: false

  alias WhoseJam.Music
  alias WhoseJam.Music.Providers.{Spotify, YouTube}

  @signed_in %{signed_in?: true, email: "host@example.com", premium?: nil}
  @env_vars ~w(YOUTUBE_API_KEY YOUTUBE_CLIENT_ID YOUTUBE_CLIENT_SECRET)

  describe "connecting" do
    test "goes through the OAuth redirect and refuses a malformed connect" do
      assert YouTube.connect_kind() == :oauth_redirect
      assert YouTube.connect(%{}) == {:error, :invalid_connect}
      assert YouTube.connect(%{"code" => "c"}) == {:error, :invalid_connect}
      assert YouTube.connect(%{"code" => 1, "redirect_uri" => "u"}) == {:error, :invalid_connect}

      assert YouTube.connect(%{"code" => "c", "redirect_uri" => nil}) ==
               {:error, :invalid_connect}
    end

    test "a signed-in account can host; anything else must sign in" do
      assert YouTube.eligible?(@signed_in)
      refute YouTube.eligible?(%{})
      refute YouTube.eligible?(%{signed_in?: "true"})
      refute YouTube.eligible?(%{email: "host@example.com", premium?: true})
    end
  end

  describe "the Premium question" do
    test "is asked of a signed-in account, naming it, and starts unanswered" do
      question = YouTube.account_question(@signed_in)

      assert question.prompt =~ "host@example.com"
      assert question.prompt =~ "YouTube Premium"
      assert question.answer == nil
    end

    test "still reads sensibly when Google shared no email" do
      question = YouTube.account_question(%{@signed_in | email: nil})
      assert question.prompt =~ "this Google account"
    end

    test "is not asked before sign-in" do
      assert YouTube.account_question(%{}) == nil
    end

    test "remembers either answer, and the answer can be changed" do
      yes = YouTube.answer_account_question(@signed_in, true)
      assert YouTube.account_question(yes).answer == true

      no = YouTube.answer_account_question(yes, false)
      assert YouTube.account_question(no).answer == false

      # Answering never signs the host out or loses the account.
      assert YouTube.eligible?(no)
      assert no.email == "host@example.com"
    end

    test "treats a non-boolean stored answer as unanswered" do
      assert YouTube.account_question(%{@signed_in | premium?: "yes"}).answer == nil
    end
  end

  describe "the ads warning" do
    test "shows until the host says the account has Premium" do
      assert YouTube.warning(@signed_in) =~ "ads"
      assert YouTube.warning(%{@signed_in | premium?: false}) =~ "ads"
      assert YouTube.warning(%{@signed_in | premium?: true}) == nil
    end

    test "is not shown for an account that isn't signed in" do
      assert YouTube.warning(%{}) == nil
      assert YouTube.warning(%{premium?: false}) == nil
    end
  end

  describe "through the facade" do
    test "the question, the answer and the warning round-trip" do
      assert Music.account_question(:youtube, @signed_in).answer == nil
      assert Music.warning(:youtube, @signed_in) =~ "ads"

      assert {:ok, answered} = Music.answer_account_question(:youtube, @signed_in, true)
      assert Music.account_question("youtube", answered).answer == true
      assert Music.warning(:youtube, answered) == nil
    end

    test "only a yes or a no is an answer" do
      assert Music.answer_account_question(:youtube, @signed_in, "yes") == :error
      assert Music.answer_account_question(:youtube, @signed_in, nil) == :error
      assert Music.answer_account_question(:youtube, nil, true) == :error
    end
  end

  describe "songs" do
    test "a video id is exactly 11 URL-safe characters" do
      assert YouTube.valid_uri?("youtube:video:dQw4w9WgXcQ")
      assert YouTube.valid_uri?("youtube:video:a-b_c-d_e-f")

      refute YouTube.valid_uri?("youtube:video:dQw4w9WgXc")
      refute YouTube.valid_uri?("youtube:video:dQw4w9WgXcQQ")
      refute YouTube.valid_uri?("youtube:video:dQw4w9WgXc!")
      refute YouTube.valid_uri?("youtube:track:dQw4w9WgXcQ")
      refute YouTube.valid_uri?("https://youtu.be/dQw4w9WgXcQ")
    end

    test "art must be a thumbnail on YouTube's image host" do
      assert YouTube.valid_art_url?("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
      assert YouTube.valid_art_url?("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault_live.jpg")

      refute YouTube.valid_art_url?("http://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
      refute YouTube.valid_art_url?("https://i.ytimg.com.evil.test/vi/dQw4w9WgXcQ/hqdefault.jpg")
      refute YouTube.valid_art_url?("https://i.ytimg.com/vi/dQw4w9WgXcQ/../x.jpg")
      refute YouTube.valid_art_url?("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg?x=1")
    end

    test "searches are debounced longer than Spotify's, to spare the daily quota" do
      assert YouTube.search_debounce_ms() == 600
      assert YouTube.search_debounce_ms() > Spotify.search_debounce_ms()
    end
  end

  describe "playback errors" do
    test "have their own wording for the failures a host can act on" do
      assert Music.playback_error_message(:youtube, %{"reason" => "embed_blocked"}) =~ "Skip"
      assert Music.playback_error_message(:youtube, %{"reason" => "video_unavailable"}) =~ "Skip"
      assert Music.playback_error_message(:youtube, %{"reason" => "autoplay_blocked"}) =~ "Click"

      assert Music.playback_error_message(:youtube, %{"reason" => "ip_address_origin"}) =~
               "localhost"
    end

    test "fall back to the generic message otherwise" do
      assert Music.playback_error_message(:youtube, %{"reason" => "???"}) =~ "unavailable"
      assert Music.playback_error_message(:youtube, %{}) =~ "unavailable"
    end
  end

  describe "credentials" do
    setup do
      previous = Map.new(@env_vars, &{&1, System.get_env(&1)})
      Enum.each(@env_vars, &System.delete_env/1)

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)
    end

    test "without them the provider is unconfigured rather than crashing" do
      refute YouTube.configured?()

      assert YouTube.authorize_url("state", "http://127.0.0.1:4000/cb") ==
               {:error, :not_configured}

      assert YouTube.search("song", %{}) == {:error, :not_configured}
      assert Music.search(:youtube, "song", %{}) == {:error, :not_configured}

      assert YouTube.connect(%{"code" => "c", "redirect_uri" => "u"}) ==
               {:error, :not_configured}
    end

    test "needs the API key and both halves of the OAuth client" do
      for missing <- @env_vars do
        Enum.each(@env_vars, &System.put_env(&1, "value"))
        System.delete_env(missing)
        refute YouTube.configured?(), "configured without #{missing}"
      end

      Enum.each(@env_vars, &System.put_env(&1, "value"))
      assert YouTube.configured?()

      System.put_env("YOUTUBE_API_KEY", "   ")
      refute YouTube.configured?()
    end

    test "the authorize URL asks Google for the smallest sign-in, on our redirect" do
      System.put_env("YOUTUBE_CLIENT_ID", "client-123")
      System.put_env("YOUTUBE_CLIENT_SECRET", "secret-456")

      assert {:ok, url} = YouTube.authorize_url("signed-state", "http://127.0.0.1:4000/cb")

      uri = URI.parse(url)
      assert uri.host == "accounts.google.com"

      assert URI.decode_query(uri.query) == %{
               "client_id" => "client-123",
               "response_type" => "code",
               "redirect_uri" => "http://127.0.0.1:4000/cb",
               "scope" => "openid email",
               "state" => "signed-state",
               "prompt" => "select_account"
             }

      refute url =~ "secret-456"
    end
  end
end
