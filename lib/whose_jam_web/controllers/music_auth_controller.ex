defmodule WhoseJamWeb.MusicAuthController do
  @moduledoc """
  Host connect flow for `:oauth_redirect` music providers (Spotify, YouTube).

  `authorize/2` sends the host off to the provider with the room code and
  provider id signed into the `state` parameter, first telling the game its
  host screen is away signing in (`WhoseJam.Game.host_signing_in/1`), so
  leaving for the provider's page doesn't end the game; `callback/2` recovers them,
  hands the provider's `connect/1` the auth code, stores the result on the
  game via `WhoseJam.Game.set_music/3`, and ends the sign-in
  (`WhoseJam.Game.host_back_from_sign_in/2`, with the sign-in id the state
  carries). Every failure branch redirects back to
  the host screen (or `/`) with a clear flash — never a crash page.

  Providers whose `connect_kind/0` is `:none` never touch this controller;
  `HostLive` connects them on click.
  """
  use WhoseJamWeb, :controller

  alias WhoseJam.{Game, Music}

  @state_salt "music_oauth_state"
  @state_max_age 900

  # =========================================================================
  # /auth/:provider?code=ROOMCODE  — kick off the OAuth redirect
  # =========================================================================

  def authorize(conn, %{"provider" => provider_id, "code" => room_code})
      when is_binary(provider_id) and is_binary(room_code) do
    with {:ok, provider} <- redirect_provider(provider_id),
         :ok <- ensure_game(room_code),
         :ok <- ensure_configured(provider) do
      # The host screen is leaving for the provider's page (it stays connected
      # until that page loads); that must not count as the host closing it.
      # The sign-in's id rides in the signed state, so only its own callback
      # can end it. Best effort: a refused notice (or a game that has just
      # gone) leaves the sign-in without an id.
      sign_in = sign_in_id(Game.host_signing_in(room_code))

      state =
        Phoenix.Token.sign(conn, @state_salt, %{
          room: room_code,
          provider: provider_id,
          sign_in: sign_in
        })

      case provider.authorize_url(state, redirect_uri(provider)) do
        {:ok, url} ->
          redirect(conn, external: url)

        {:error, _} ->
          conn
          |> back_from_sign_in(room_code, sign_in)
          |> failure(:not_configured, provider, room_code)
      end
    else
      {:error, reason, provider} -> failure(conn, reason, provider, room_code)
    end
  end

  def authorize(conn, _params) do
    conn
    |> put_flash(:error, "Missing room code for the music connection.")
    |> redirect(to: ~p"/")
  end

  # =========================================================================
  # /auth/:provider/callback  — the provider redirects back here
  # =========================================================================

  # Host denied the authorization prompt.
  def callback(conn, %{"error" => _error, "state" => state} = params) when is_binary(state) do
    case recover_state(conn, params["provider"], state) do
      {:ok, room_code, provider, sign_in} ->
        conn
        |> back_from_sign_in(room_code, sign_in)
        |> put_flash(:error, "#{provider.name()} connection was cancelled.")
        |> redirect(to: ~p"/host/#{room_code}")

      :error ->
        conn
        |> put_flash(:error, "The music connection was cancelled.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, %{"code" => auth_code, "state" => state} = params)
      when is_binary(auth_code) and is_binary(state) do
    case recover_state(conn, params["provider"], state) do
      {:ok, room_code, provider, sign_in} ->
        conn
        |> finish_callback(provider, room_code, auth_code)
        |> back_from_sign_in(room_code, sign_in)

      :error ->
        conn
        |> put_flash(:error, "The music connection could not be verified. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "The music service returned an unexpected response. Please try again.")
    |> redirect(to: ~p"/")
  end

  # =========================================================================
  # Internals
  # =========================================================================

  defp finish_callback(conn, provider, room_code, auth_code) do
    params = %{"code" => auth_code, "redirect_uri" => redirect_uri(provider)}

    with {:ok, auth} <- provider.connect(params),
         :ok <- Game.set_music(room_code, provider.id(), auth) do
      conn
      |> put_connected_flash(provider, provider.eligible?(auth))
      |> redirect(to: ~p"/host/#{room_code}")
    else
      {:error, reason} -> failure(conn, reason, provider, room_code)
    end
  end

  defp sign_in_id({:ok, sign_in}), do: sign_in
  defp sign_in_id(_refused), do: nil

  # However the sign-in went, it is over and the host screen is on its way
  # back: the game's usual host-screen grace applies again. Only a sign-in the
  # game let in has an id to end (best effort, as in `authorize/2`).
  defp back_from_sign_in(conn, room_code, sign_in) when is_binary(sign_in) do
    _ = Game.host_back_from_sign_in(room_code, sign_in)
    conn
  end

  defp back_from_sign_in(conn, _room_code, _no_sign_in), do: conn

  defp put_connected_flash(conn, provider, true) do
    put_flash(conn, :info, "#{provider.name()} connected — you're ready to host playback.")
  end

  defp put_connected_flash(conn, provider, false) do
    put_flash(conn, :error, provider.ineligible_message())
  end

  defp redirect_provider(provider_id) do
    case Music.fetch_provider(provider_id) do
      {:ok, provider} ->
        if provider.connect_kind() == :oauth_redirect,
          do: {:ok, provider},
          else: {:error, :not_redirect, provider}

      :error ->
        {:error, :unknown_provider, nil}
    end
  end

  defp ensure_game(room_code) do
    if Game.exists?(room_code), do: :ok, else: {:error, :no_game, nil}
  end

  defp ensure_configured(provider) do
    if provider.configured?(), do: :ok, else: {:error, :not_configured, provider}
  end

  defp failure(conn, reason, provider, room_code) do
    {message, to} = failure_message(reason, provider, room_code)

    conn
    |> put_flash(:error, message)
    |> redirect(to: to)
  end

  defp failure_message(:no_game, _provider, _room), do: {"That game no longer exists.", ~p"/"}

  defp failure_message(:unknown_provider, _provider, _room),
    do: {"Unknown music service.", ~p"/"}

  defp failure_message(:not_redirect, provider, room),
    do: {"#{provider.name()} doesn't connect this way.", ~p"/host/#{room}"}

  defp failure_message(:not_configured, provider, room),
    do: {"#{provider.name()} isn't configured on the server.", ~p"/host/#{room}"}

  defp failure_message(:not_lobby, _provider, room),
    do: {"The game has started — you can't switch music service now.", ~p"/host/#{room}"}

  defp failure_message(_reason, provider, room),
    do:
      {"Couldn't complete the #{provider.name()} connection. Please try again.",
       ~p"/host/#{room}"}

  # The redirect URI sent to the provider. It must exactly match — including
  # port — one registered with the provider. In order:
  #
  #   1. `config :whose_jam, :<id>_redirect_uri`, when set (runtime.exs fills
  #      it from SPOTIFY_REDIRECT_URI / YOUTUBE_REDIRECT_URI).
  #   2. Served over https: the app's own public URL (PHX_SCHEME, PHX_HOST and
  #      URL_PORT), which is what a provider accepts for a deployed domain.
  #   3. Otherwise a loopback URI, see `loopback_redirect_uri/1`.
  #
  # The interpolated atom is safe: `provider` is always one of the configured
  # provider modules (resolved via Music.fetch_provider/1), never raw input.
  # sobelow_skip ["DOS.BinToAtom"]
  defp redirect_uri(provider) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    Application.get_env(:whose_jam, :"#{provider.id()}_redirect_uri") ||
      default_redirect_uri(provider)
  end

  defp default_redirect_uri(provider) do
    public_url = WhoseJamWeb.Endpoint.url()

    case URI.parse(public_url) do
      %URI{scheme: "https"} -> public_url <> "/auth/#{provider.id()}/callback"
      _plain_http -> loopback_redirect_uri(provider)
    end
  end

  # Over plain http the public URL is no use: at a party PHX_HOST is the
  # laptop's LAN IP, Spotify rejects any non-https redirect that isn't a
  # loopback IP, and Google rejects any that isn't `localhost`. The OAuth
  # round-trip only happens in the host's browser on the machine running the
  # server, so a loopback URI always works: http://127.0.0.1:<public port>, or
  # the loopback host the provider asks for with `redirect_host/0` — YouTube
  # uses `localhost`, because the host screen stays on the redirect's host
  # afterwards and YouTube's player won't play on a page opened by IP address.
  defp loopback_redirect_uri(provider) do
    "http://#{Music.redirect_host(provider)}:#{public_port()}/auth/#{provider.id()}/callback"
  end

  defp public_port do
    endpoint_config = WhoseJamWeb.Endpoint.config(:url) || []
    endpoint_config[:port] || WhoseJamWeb.Endpoint.config(:http)[:port] || 4000
  end

  # The state must verify, and its provider must be the one in the callback path.
  # The sign-in id is nil when the game refused the notice.
  defp recover_state(conn, path_provider, state) do
    with {:ok, %{room: room_code, provider: provider_id} = signed} <-
           Phoenix.Token.verify(conn, @state_salt, state, max_age: @state_max_age),
         true <- provider_id == path_provider,
         {:ok, provider} <- Music.fetch_provider(provider_id) do
      {:ok, room_code, provider, Map.get(signed, :sign_in)}
    else
      _ -> :error
    end
  end
end
