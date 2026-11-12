defmodule WhoseJam.Music.Provider do
  @moduledoc """
  Behaviour every music provider (Spotify, YouTube, the dev-only Mock, ...) implements.

  A game is bound to exactly one provider, chosen by the host in the lobby. The
  game runtime itself is provider-neutral — it only ever stores
  `%{uri, name, artist, album_art_url}` songs — so everything that varies lives
  behind these callbacks. There are eight places where providers really differ:

    1. **Identity & host-facing copy** — `id/0`, `name/0`, `requirement/0`,
       `ineligible_message/0`.
    2. **Catalog search** — `search/2`, `search_debounce_ms/0`, `valid_uri?/1`,
       `valid_art_url?/1`.
    3. **Host connection** — `connect_kind/0`, `connect/1` (+ `authorize_url/2`).
    4. **Eligibility** — `eligible?/1` (e.g. Spotify Premium).
    5. **Token upkeep** — `refresh/1` (optional).
    6. **Browser player** — `client_config/1`, handed to the JS player module of
       the same id (`assets/js/hooks/music/<id>.js`), and the optional
       `playback_error_message/1` for its failures.
    7. **Capabilities** — `configured?/0` (does the server have what it needs?)
       and `video?/0` (does the TV need to show the player?).
    8. **What the server can't verify** — `account_question/1`,
       `answer_account_question/2` and `warning/1` (all optional; see below).

  ## Song URIs

  A song's `uri` is a provider-namespaced string (`spotify:track:…`,
  `youtube:video:…`, `mock:track:…`). The namespace is what stops a player
  submitting one provider's song into another provider's room.

  ## The host `auth` map

  `connect/1` returns an opaque, provider-specific `auth` map (tokens,
  storefront, ...). The game stores it and exposes it only through the
  host-scoped view. By convention an optional `:expires_at` (`DateTime`) key
  drives the host screen's refresh timer.

  ## Connect kinds

    * `:oauth_redirect` — the host is redirected to the provider and back
      (`authorize_url/2` then `connect(%{"code" => c, "redirect_uri" => u})`).
    * `:none` — nothing to authorize (`connect(%{})`).

  A provider that authorizes inside the host's browser (e.g. MusicKit's sign-in
  popup) would need a third kind; none ships today, so it is left out until the
  first one does.

  ## Account questions and warnings

  `eligible?/1` is for what the server can check and the game cannot run
  without (Spotify Premium). Some things matter but can't be checked: Google
  has no API that reports YouTube Premium. For those a provider asks the host:

    * `account_question/1` returns a yes/no question about the connected
      account, with the host's `:answer` so far (`nil` until they answer). The
      host screen asks it as soon as the account is connected.
    * `answer_account_question/2` records the answer in the `auth` map, which
      the host screen then stores with `WhoseJam.Game.set_music/3`.
    * `warning/1` returns host-facing copy when playback will work but be worse
      than it could be (ads without Premium). It never blocks the game.
  """

  @type id :: atom()
  @type auth :: map()
  @type track :: WhoseJam.Music.Track.t()
  @type connect_kind :: :oauth_redirect | :none
  @type account_question :: %{prompt: String.t(), detail: String.t(), answer: boolean() | nil}

  # --- identity & capabilities ---------------------------------------------

  @doc "Stable machine id (`:spotify`). Also the JS player module name and URL segment."
  @callback id() :: id()

  @doc "Host-facing display name (\"Spotify\")."
  @callback name() :: String.t()

  @doc "Host-facing one-liner on what the service needs (\"Premium account required…\")."
  @callback requirement() :: String.t()

  @doc "Host-facing message when a connected account fails `eligible?/1`."
  @callback ineligible_message() :: String.t()

  @doc "How the host connects: an OAuth redirect round-trip, or nothing at all."
  @callback connect_kind() :: connect_kind()

  @doc "Whether playback is visual and the TV must show the player."
  @callback video?() :: boolean()

  @doc "Whether the server has what it needs (credentials, keys) to use this provider."
  @callback configured?() :: boolean()

  # --- catalog ---------------------------------------------------------------

  @doc """
  Search the provider's catalog. Returns up to a handful of tracks, or
  `{:error, :not_configured}` / `{:error, :quota_exceeded}` (the provider's
  search allowance is used up) / `{:error, term}`. Caching, query
  normalization and blank-query handling are done by `WhoseJam.Music`.
  """
  @callback search(query :: String.t(), auth()) :: {:ok, [track()]} | {:error, term()}

  @doc """
  How long (ms) the player screen waits after the last keystroke before it
  searches. Raise it for a provider whose searches are scarce (YouTube's daily
  quota).
  """
  @callback search_debounce_ms() :: pos_integer()

  @doc "Whether `uri` is a well-formed song URI of this provider."
  @callback valid_uri?(uri :: String.t()) :: boolean()

  @doc "Whether `url` is album art hosted where this provider's art lives."
  @callback valid_art_url?(url :: String.t()) :: boolean()

  # --- host connection -------------------------------------------------------

  @doc "Where to send the host to authorize (`:oauth_redirect` providers only)."
  @callback authorize_url(state :: String.t(), redirect_uri :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  The loopback host in the default OAuth redirect URI when the app is served
  over plain http (`http://<host>:<port>/auth/<id>/callback`), which is also
  where the host screen ends up after connecting. Over https the default is
  the app's own public URL and this is not used. Optional; defaults to
  `"127.0.0.1"`, the only loopback Spotify accepts. YouTube returns
  `"localhost"`: its player refuses to play on a page opened by IP address.
  """
  @callback redirect_host() :: String.t()

  @doc "Turn the connect input for this provider's kind into a host `auth` map."
  @callback connect(params :: map()) :: {:ok, auth()} | {:error, term()}

  @doc "Whether the connected account can actually play full songs."
  @callback eligible?(auth()) :: boolean()

  @doc "Obtain fresh credentials. Optional; providers without expiry omit it."
  @callback refresh(auth()) :: {:ok, auth()} | {:error, term()}

  # --- browser ----------------------------------------------------------------

  @doc "JSON-encodable config for the browser player (`data-config`)."
  @callback client_config(auth()) :: map()

  # --- optional ---------------------------------------------------------------

  @doc "Host-facing message for a browser `playback_error` payload, or `nil` for the generic one."
  @callback playback_error_message(params :: map()) :: String.t() | nil

  @doc """
  A yes/no question for the host about the connected account, or `nil` when
  there is nothing to ask. `:answer` is `nil` until the host has answered.
  """
  @callback account_question(auth()) :: account_question() | nil

  @doc "Record the host's answer to `account_question/1` in `auth`."
  @callback answer_account_question(auth(), answer :: boolean()) :: auth()

  @doc "Host-facing warning when playback works but is degraded, or `nil`."
  @callback warning(auth()) :: String.t() | nil

  @optional_callbacks authorize_url: 2,
                      redirect_host: 0,
                      refresh: 1,
                      playback_error_message: 1,
                      account_question: 1,
                      answer_account_question: 2,
                      warning: 1
end
