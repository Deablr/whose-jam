defmodule WhoseJam.Music.Cache do
  @moduledoc """
  In-memory caches shared by every music provider.

  Owns two things:

    * **Token cache** — one app-level bearer token per key (e.g. `:spotify`),
      fetched lazily by a caller-supplied function and reused until it is near
      expiry. Fetches are serialized through this GenServer so concurrent
      searches never trigger a thundering herd of token requests.
    * **Search result cache** — results keyed by `{provider, scope, term}` with
      a short TTL (~5 min), to keep repeated identical searches (a room full of
      people typing the same hit) off the provider's API.

  It is safe to start with no provider configured — the ETS tables are created
  but stay empty.
  """

  use GenServer

  @token_table :whose_jam_music_token
  @search_table :whose_jam_music_search

  # Refresh a token this many seconds before its real expiry, to absorb clock
  # skew and in-flight request latency.
  @token_expiry_margin_s 60

  # How long a cached search result stays fresh.
  @search_ttl_s 300

  # A token fetch can take up to the HTTP receive timeout; wait a little longer.
  @call_timeout_ms 10_000

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Returns a currently-valid token for `key`, calling `fetch` (inside the cache
  process, so serialized) when none is cached or it is near expiry.

  `fetch` must return `{:ok, %{access_token: String.t(), expires_in: pos_integer()}}`
  or `{:error, term()}`.
  """
  @spec fetch_token(term(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_token(key, fetch) when is_function(fetch, 0) do
    GenServer.call(__MODULE__, {:fetch_token, key, fetch}, @call_timeout_ms)
  catch
    :exit, _ -> {:error, :cache_unavailable}
  end

  @doc """
  Looks up cached search results under `key`. Returns `{:ok, results}` on a
  fresh hit, or `:miss`. Reads straight from ETS; safe before the cache starts.
  """
  @spec get_cached_search(term()) :: {:ok, list()} | :miss
  def get_cached_search(key) do
    case :ets.lookup(@search_table, key) do
      [{^key, results, expires_at}] ->
        if now() < expires_at, do: {:ok, results}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Stores search `results` under `key` with the module's TTL. Best-effort."
  @spec put_cached_search(term(), list()) :: :ok
  def put_cached_search(key, results) do
    :ets.insert(@search_table, {key, results, now() + @search_ttl_s})
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
  def handle_call({:fetch_token, key, fetch}, _from, state) do
    {:reply, ensure_token(key, fetch), state}
  end

  defp ensure_token(key, fetch) do
    case :ets.lookup(@token_table, key) do
      [{^key, token, expires_at}] when expires_at > 0 ->
        if now() < expires_at - @token_expiry_margin_s do
          {:ok, token}
        else
          fetch_and_cache(key, fetch)
        end

      _ ->
        fetch_and_cache(key, fetch)
    end
  end

  defp fetch_and_cache(key, fetch) do
    case fetch.() do
      {:ok, %{access_token: token, expires_in: expires_in}} ->
        :ets.insert(@token_table, {key, token, now() + expires_in})
        {:ok, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp now, do: System.system_time(:second)
end
