defmodule WhoseJam.Spotify.Cache do
  @moduledoc """
  In-memory caches for the app-level Spotify integration.

  Owns two things:

    * **App token cache** — the Client Credentials token, fetched lazily and
      reused until it is near expiry, then transparently refreshed. Token
      fetches are serialized through this GenServer so concurrent searches
      never trigger a thundering herd of token requests.
    * **Search result cache** — search results keyed by normalized search term
      with a short TTL (~5 min), to keep repeated identical searches (a room
      full of people typing the same hit) off the Spotify API.

  ## Supervision

  This is the single child-spec entry point the orchestrator wires into the
  supervision tree:

      children = [
        # ...
        WhoseJam.Spotify.Cache
      ]

  It is safe to start even when Spotify credentials are absent — the ETS tables
  are created but stay empty, and `WhoseJam.Spotify.search/1` short-circuits to
  `{:error, :not_configured}` before ever consulting the cache.
  """

  use GenServer

  alias WhoseJam.Spotify.Client

  @token_table :whose_jam_spotify_token
  @search_table :whose_jam_spotify_search

  # Refresh the app token this many seconds before its real expiry, to absorb
  # clock skew and in-flight request latency.
  @token_expiry_margin_s 60

  # How long a cached search result stays fresh.
  @search_ttl_s 300

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Returns a currently-valid app-level access token, fetching or refreshing one
  if needed. Serialized: at most one token fetch is in flight at a time.

  ## Returns

    * `{:ok, token}` — a valid bearer token.
    * `{:error, :not_configured}` — app credentials absent.
    * `{:error, term()}` — token fetch failed.
  """
  @spec get_app_token() :: {:ok, String.t()} | {:error, term()}
  def get_app_token do
    GenServer.call(__MODULE__, :get_app_token)
  catch
    :exit, _ -> {:error, :cache_unavailable}
  end

  @doc """
  Looks up cached results for a normalized search `term`.

  Returns `{:ok, results}` on a fresh hit, or `:miss` when absent or expired.
  Reads directly from ETS (no GenServer round-trip). Safe before the cache is
  started — returns `:miss` if the table does not yet exist.
  """
  @spec get_cached_search(String.t()) :: {:ok, list()} | :miss
  def get_cached_search(term) do
    case :ets.lookup(@search_table, term) do
      [{^term, results, expires_at}] ->
        if now() < expires_at, do: {:ok, results}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Stores search `results` under a normalized `term` with the module's TTL.

  Best-effort: a no-op if the cache table does not yet exist. Writes directly
  to ETS.
  """
  @spec put_cached_search(String.t(), list()) :: :ok
  def put_cached_search(term, results) do
    :ets.insert(@search_table, {term, results, now() + @search_ttl_s})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@token_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@search_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call(:get_app_token, _from, state) do
    {:reply, ensure_token(), state}
  end

  # Returns a valid token from ETS if one is cached and not near expiry,
  # otherwise fetches a fresh one and caches it.
  defp ensure_token do
    case :ets.lookup(@token_table, :app_token) do
      [{:app_token, token, expires_at}] when expires_at > 0 ->
        if now() < expires_at - @token_expiry_margin_s do
          {:ok, token}
        else
          fetch_and_cache_token()
        end

      _ ->
        fetch_and_cache_token()
    end
  end

  defp fetch_and_cache_token do
    case Client.fetch_app_token() do
      {:ok, %{access_token: token, expires_in: expires_in}} ->
        :ets.insert(@token_table, {:app_token, token, now() + expires_in})
        {:ok, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp now, do: System.system_time(:second)
end
