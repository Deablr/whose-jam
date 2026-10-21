defmodule WhoseJam.Music.Providers.Spotify do
  @moduledoc """
  Spotify, via two independent credentials:

    * **Search** — the app-level Client Credentials token
      (`WhoseJam.Spotify.Client`), cached by `WhoseJam.Music.Cache`. The secret
      never leaves the server.
    * **Playback** — the host's Premium account, connected through the OAuth
      Authorization Code flow (`WhoseJam.Spotify.Auth`) and played by the Web
      Playback SDK in the host browser (`assets/js/hooks/music/spotify.js`).

  Credentials come from `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET`, read at
  runtime.
  """

  @behaviour WhoseJam.Music.Provider

  alias WhoseJam.Music.Cache
  alias WhoseJam.Spotify.{Auth, Client, Credentials}

  @uri_regex ~r/\Aspotify:track:[A-Za-z0-9]{22}\z/
  @art_regex ~r{\Ahttps://i\.scdn\.co/image/[A-Za-z0-9]+\z}

  @impl true
  def id, do: :spotify

  @impl true
  def name, do: "Spotify"

  @impl true
  def requirement, do: "Premium account required for full-song playback."

  @impl true
  def ineligible_message,
    do:
      "That Spotify account isn't Premium — you can't host playback. " <>
        "Connect a Premium account to start the game."

  @impl true
  def connect_kind, do: :oauth_redirect

  @impl true
  def video?, do: false

  @impl true
  def configured?, do: Credentials.configured?()

  @impl true
  def search(query, _auth) do
    with {:ok, token} <- Cache.fetch_token(:spotify, &Client.fetch_app_token/0) do
      Client.search_tracks(token, query)
    end
  end

  @impl true
  def valid_uri?(uri), do: Regex.match?(@uri_regex, uri)

  @impl true
  def valid_art_url?(url), do: Regex.match?(@art_regex, url)

  @impl true
  def authorize_url(state, redirect_uri) do
    case Auth.authorize_url(state, redirect_uri) do
      url when is_binary(url) -> {:ok, url}
      {:error, _} = error -> error
    end
  end

  @impl true
  def connect(%{"code" => code, "redirect_uri" => redirect_uri}) do
    with {:ok, tokens} <- Auth.exchange_code(code, redirect_uri),
         {:ok, premium?} <- Auth.premium?(tokens.access_token) do
      {:ok, Map.put(tokens, :premium?, premium?)}
    end
  end

  def connect(_params), do: {:error, :invalid_connect}

  @impl true
  def eligible?(auth), do: Map.get(auth, :premium?) == true

  @impl true
  def refresh(%{refresh_token: refresh_token}), do: Auth.refresh(refresh_token)
  def refresh(_auth), do: {:error, :no_refresh_token}

  @impl true
  def client_config(auth), do: %{token: Map.get(auth, :access_token)}

  @impl true
  def playback_error_message(%{"reason" => "initialization_error"}),
    do:
      "This browser can't play protected Spotify audio (DRM/Widevine unavailable). " <>
        "Open this page in desktop Chrome, Edge, or Firefox — built-in app browsers " <>
        "(editor/IDE previews, Electron apps) don't include Widevine. Use https, or " <>
        "localhost on this machine; http on a LAN IP also disables DRM."

  def playback_error_message(%{"reason" => "no_token"}),
    do: "No Spotify token — reconnect Spotify in Settings."

  def playback_error_message(%{"reason" => "authentication_error"}),
    do: "Spotify rejected the token — reconnect Spotify in Settings."

  def playback_error_message(%{"reason" => "account_error"}),
    do: "Spotify playback needs a Premium account."

  def playback_error_message(_params), do: nil
end
