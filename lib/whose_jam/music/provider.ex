defmodule WhoseJam.Music.Provider do
  @moduledoc """
  Behaviour every music provider (Spotify, the dev-only Mock, ...) implements.

  A game is bound to exactly one provider, chosen by the host in the lobby. The
  game runtime itself is provider-neutral — it only ever stores
  `%{uri, name, artist, album_art_url}` songs — so everything that varies lives
  behind these callbacks. There are six places where providers really differ:

    1. **Catalog search** — `search/2`, `valid_uri?/1`, `valid_art_url?/1`.
    2. **Host connection** — `connect_kind/0`, `connect/1` (+ `authorize_url/2`).
    3. **Eligibility** — `eligible?/1` (e.g. Spotify Premium).
    4. **Token upkeep** — `refresh/1`.
    5. **Browser player** — `client_config/1`, handed to the JS player module of
       the same id (`assets/js/hooks/music/<id>.js`).
    6. **Capabilities** — `video?/0` (does the TV need to show the player?).

  ## Song URIs

  A song's `uri` is a provider-namespaced string (`spotify:track:…`,
  `mock:track:…`). The namespace is what stops a player submitting one
  provider's song into another provider's room.

  ## The host `auth` map

  `connect/1` returns an opaque, provider-specific `auth` map (tokens,
  storefront, ...). The game stores it and exposes it only through the
  host-scoped view. By convention an optional `:expires_at` (`DateTime`) key
  drives the host screen's refresh timer.

  ## Connect kinds

    * `:oauth_redirect` — the host is redirected to the provider and back
      (`authorize_url/2` then `connect(%{"code" => c, "redirect_uri" => u})`).
    * `:browser` — the provider authorizes inside the host's browser (the JS
      module's `authorize/1`); its result is passed to `connect/1`.
    * `:none` — nothing to authorize (`connect(%{})`).
  """

  @type id :: atom()
  @type auth :: map()
  @type track :: WhoseJam.Music.Track.t()
  @type connect_kind :: :oauth_redirect | :browser | :none

  # --- identity & capabilities ---------------------------------------------

  @doc "Stable machine id (`:spotify`). Also the JS player module name and URL segment."
  @callback id() :: id()

  @doc "Host-facing display name (\"Spotify\")."
  @callback name() :: String.t()

  @doc "Host-facing one-liner on what the service needs (\"Premium account required…\")."
  @callback requirement() :: String.t()

  @doc "Host-facing message when a connected account fails `eligible?/1`."
  @callback ineligible_message() :: String.t()

  @callback connect_kind() :: connect_kind()

  @doc "Whether playback is visual and the TV must show the player."
  @callback video?() :: boolean()

  @doc "Whether the server has what it needs (credentials, keys) to use this provider."
  @callback configured?() :: boolean()

  # --- catalog ---------------------------------------------------------------

  @doc """
  Search the provider's catalog. Returns up to a handful of tracks, or
  `{:error, :not_configured}` / `{:error, term}`. Caching, query
  normalization and blank-query handling are done by `WhoseJam.Music`.
  """
  @callback search(query :: String.t(), auth()) :: {:ok, [track()]} | {:error, term()}

  @doc "Whether `uri` is a well-formed song URI of this provider."
  @callback valid_uri?(uri :: String.t()) :: boolean()

  @doc "Whether `url` is album art hosted where this provider's art lives."
  @callback valid_art_url?(url :: String.t()) :: boolean()

  # --- host connection -------------------------------------------------------

  @doc "Where to send the host to authorize (`:oauth_redirect` providers only)."
  @callback authorize_url(state :: String.t(), redirect_uri :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Turn the connect input for this provider's kind into a host `auth` map."
  @callback connect(params :: map()) :: {:ok, auth()} | {:error, term()}

  @doc "Whether the connected account can actually play full songs."
  @callback eligible?(auth()) :: boolean()

  @doc "Obtain fresh credentials. Optional; providers without expiry omit it."
  @callback refresh(auth()) :: {:ok, auth()} | {:error, term()}

  # --- browser ----------------------------------------------------------------

  @doc """
  JSON-encodable config for the browser player (`data-config`). Called with
  `%{}` before connecting too, for `:browser` providers that need a public
  token to authorize.
  """
  @callback client_config(auth()) :: map()

  # --- optional ---------------------------------------------------------------

  @doc "Extra cache-key scope for search (e.g. a storefront), when results depend on auth."
  @callback search_scope(auth()) :: term()

  @doc "Host-facing message for a browser `playback_error` payload, or `nil` for the generic one."
  @callback playback_error_message(params :: map()) :: String.t() | nil

  @optional_callbacks authorize_url: 2,
                      refresh: 1,
                      search_scope: 1,
                      playback_error_message: 1
end
