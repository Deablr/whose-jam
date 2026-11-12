defmodule WhoseJam.Music.Providers.YouTube do
  @moduledoc """
  YouTube: music videos, played by the IFrame player on the host screen
  (`assets/js/hooks/music/youtube.js`).

    * **Search** — the YouTube Data API with the server's API key
      (`WhoseJam.YouTube.Client`). Google allows roughly 100 searches a day per
      Cloud project, so this provider asks for a longer search debounce.
    * **Host connection** — a Google sign-in (`WhoseJam.YouTube.Auth`). A
      signed-in account is all it takes to host: `eligible?/1`.
    * **Premium** — makes playback ad-free, but Google has no API that reports
      it. So the host is asked (`account_question/1`), and anything other than
      "yes" produces a `warning/1` about ads. The game still starts.
    * **Playback** — `video?/0` is true: YouTube's terms require the player to
      be visible, so the host screen shows it in place of the album art.

  The player is embedded from `www.youtube.com`, so it runs with whatever
  YouTube session the host's browser has. That is why the sign-in happens in
  the browser that plays the songs — and why ads can still appear for a Premium
  account if the browser blocks third-party cookies.

  ## The host screen's address

  YouTube refuses to play ("This video is unavailable") in a page opened by IP
  address — `127.0.0.1`, `[::1]` or a LAN IP — and plays in one opened by
  name (`localhost`, `laptop.local`, a domain). So `redirect_host/0` is
  `localhost`, which is where the sign-in leaves the host screen when the app
  is served over plain http (over https it returns to the app's own domain),
  and the browser player reports `ip_address_origin` rather than trying.

  Credentials come from `YOUTUBE_API_KEY`, `YOUTUBE_CLIENT_ID` and
  `YOUTUBE_CLIENT_SECRET`, read at runtime.

  ## The host `auth` map

  `%{signed_in?: true, premium?: boolean() | nil}` — `premium?` is `nil` until
  the host answers the question. No tokens and no account identity are kept:
  the host screen is shown to the whole room.
  """

  @behaviour WhoseJam.Music.Provider

  alias WhoseJam.YouTube.{Auth, Client, Credentials}

  @uri_regex ~r/\Ayoutube:video:[A-Za-z0-9_-]{11}\z/
  @art_regex ~r|\Ahttps://i\.ytimg\.com/vi/[A-Za-z0-9_-]{11}/[a-z0-9_]+\.jpg\z|

  @ads_warning "Without YouTube Premium, ads can play before or during a song, " <>
                 "so rounds may start late or be interrupted."

  @impl true
  def id, do: :youtube

  @impl true
  def name, do: "YouTube"

  @impl true
  def requirement,
    do: "Google sign-in required. YouTube Premium recommended — it plays without ads."

  @impl true
  def ineligible_message, do: "Sign in with Google to host with YouTube."

  @impl true
  def connect_kind, do: :oauth_redirect

  @impl true
  def video?, do: true

  @impl true
  def configured?, do: Credentials.configured?()

  @impl true
  def search(query, _auth), do: Client.search_videos(query)

  # Every search spends scarce daily quota, so wait for a longer pause in typing.
  @impl true
  def search_debounce_ms, do: 600

  @impl true
  def valid_uri?(uri), do: Regex.match?(@uri_regex, uri)

  @impl true
  def valid_art_url?(url), do: Regex.match?(@art_regex, url)

  @impl true
  def authorize_url(state, redirect_uri), do: Auth.authorize_url(state, redirect_uri)

  @impl true
  def redirect_host, do: "localhost"

  @impl true
  def connect(%{"code" => code, "redirect_uri" => redirect_uri})
      when is_binary(code) and is_binary(redirect_uri) do
    with :ok <- Auth.sign_in(code, redirect_uri) do
      {:ok, %{signed_in?: true, premium?: nil}}
    end
  end

  def connect(_params), do: {:error, :invalid_connect}

  @impl true
  def eligible?(auth), do: Map.get(auth, :signed_in?) == true

  @impl true
  def client_config(_auth), do: %{}

  @impl true
  def account_question(auth) do
    if eligible?(auth) do
      %{
        prompt: "Does the Google account you signed in with have YouTube Premium?",
        detail:
          "YouTube can't tell us, so we have to ask. With Premium, songs play without ads " <>
            "on this screen — as long as this browser is signed in to YouTube with that account.",
        answer: premium_answer(auth)
      }
    end
  end

  @impl true
  def answer_account_question(auth, answer) when is_boolean(answer),
    do: Map.put(auth, :premium?, answer)

  @impl true
  def warning(auth) do
    if eligible?(auth) and premium_answer(auth) != true, do: @ads_warning
  end

  @impl true
  def playback_error_message(%{"reason" => "embed_blocked"}),
    do: "This video's owner doesn't allow it to be played outside YouTube. Skip the song."

  def playback_error_message(%{"reason" => "video_unavailable"}),
    do: "This video was removed or made private. Skip the song."

  def playback_error_message(%{"reason" => "ip_address_origin"}),
    do:
      "YouTube won't play on a page opened by IP address (such as 127.0.0.1). Open this " <>
        "screen by name instead, keeping the port and path: localhost if the game runs on " <>
        "this computer, otherwise the hostname the server is set up with (PHX_HOST)."

  def playback_error_message(%{"reason" => "autoplay_blocked"}),
    do: "The browser blocked the video from starting. Click the video on this screen to play it."

  def playback_error_message(%{"reason" => "sdk_load_failed"}),
    do: "Couldn't load the YouTube player. Check this screen's internet connection."

  def playback_error_message(_params), do: nil

  defp premium_answer(auth) do
    case Map.get(auth, :premium?) do
      answer when is_boolean(answer) -> answer
      _other -> nil
    end
  end
end
