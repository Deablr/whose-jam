defmodule WhoseJam.Music do
  @moduledoc """
  Provider-neutral facade over the music providers
  (see `WhoseJam.Music.Provider`).

  Everything that works the same for every provider lives here: which
  providers are enabled, search (query normalization + result cache), song
  validation, and host-token upkeep. Provider modules only implement what
  genuinely differs.

  ## Enabled providers

  `config :whose_jam, :music_providers, [module, ...]` — defaults to Spotify
  only. Dev and test also enable the fake `Mock` provider.
  """

  alias WhoseJam.Music.{Cache, Track}
  alias WhoseJam.Music.Providers.Spotify

  # Refresh a host token this long before it expires; never poll faster than
  # the floor.
  @refresh_lead_s 60
  @refresh_floor_ms 30_000

  @doc "The enabled provider modules, in display order."
  @spec providers() :: [module()]
  def providers, do: Application.get_env(:whose_jam, :music_providers, [Spotify])

  @doc """
  Look up an enabled provider by id (atom, or the string form a URL / event
  carries). Never creates atoms from the input.
  """
  @spec fetch_provider(term()) :: {:ok, module()} | :error
  def fetch_provider(id) when is_atom(id) or is_binary(id) do
    case Enum.find(providers(), &(Atom.to_string(&1.id()) == to_string(id))) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  def fetch_provider(_id), do: :error

  @doc """
  Search `provider_id`'s catalog for `query`, using the room's host `auth`.

  A blank query returns `{:ok, []}` without any network call. The provider is
  searched with the *normalized* query (case-insensitive, whitespace-collapsed)
  and results are cached under it, so repeated identical searches don't hit the
  provider and a provider's quirks can't poison the shared entry. Errors are
  never cached. Returns `{:error, :unknown_provider}` or
  `{:error, :not_configured}` before searching.
  """
  @spec search(atom(), String.t(), map()) :: {:ok, [Track.t()]} | {:error, term()}
  def search(provider_id, query, auth) when is_binary(query) do
    case fetch_provider(provider_id) do
      {:ok, mod} -> search_with(mod, normalize_query(query), auth)
      :error -> {:error, :unknown_provider}
    end
  end

  defp search_with(mod, normalized, auth) do
    cond do
      normalized == "" -> {:ok, []}
      not mod.configured?() -> {:error, :not_configured}
      true -> cached_search(mod, normalized, auth)
    end
  end

  defp cached_search(mod, normalized, auth) do
    key = {mod.id(), normalized}

    case Cache.get_cached_search(key) do
      {:ok, results} ->
        {:ok, results}

      :miss ->
        with {:ok, results} <- mod.search(normalized, auth) do
          Cache.put_cached_search(key, results)
          {:ok, results}
        end
    end
  end

  # "  Bohemian   RHAPSODY " and "bohemian rhapsody" share a cache entry.
  defp normalize_query(query) do
    query
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  @doc "Validate a client-submitted song for `provider_id` (see `WhoseJam.Music.Track`)."
  @spec normalize_track(atom(), term()) :: {:ok, Track.t()} | {:error, :invalid_song}
  def normalize_track(provider_id, song) do
    case fetch_provider(provider_id) do
      {:ok, mod} -> Track.normalize(mod, song)
      :error -> {:error, :invalid_song}
    end
  end

  @doc "Host-facing message for a browser `playback_error` payload."
  @spec playback_error_message(atom() | nil, map()) :: String.t()
  def playback_error_message(provider_id, params) do
    with {:ok, mod} <- fetch_provider(provider_id),
         message when is_binary(message) <- optional(mod, :playback_error_message, [params], nil) do
      message
    else
      _ -> "Music playback is unavailable right now."
    end
  end

  @doc """
  Refresh `auth` when it is within the refresh lead of expiring.

  Returns `{auth, changed?}`: the (possibly new) auth, and whether it changed
  and so needs storing. A failed refresh keeps the old auth.
  """
  @spec refresh_if_due(module(), map()) :: {map(), boolean()}
  def refresh_if_due(mod, auth) do
    with %DateTime{} = expires_at <- Map.get(auth, :expires_at),
         true <- DateTime.compare(expires_at, due_threshold()) != :gt,
         {:ok, fresh} <- optional(mod, :refresh, [auth], :none) do
      {Map.merge(auth, fresh), true}
    else
      _ -> {auth, false}
    end
  end

  @doc "Milliseconds until `auth` next needs a refresh check, or `nil` if it never expires."
  @spec refresh_delay_ms(map()) :: pos_integer() | nil
  def refresh_delay_ms(%{expires_at: %DateTime{} = expires_at}) do
    secs = DateTime.diff(expires_at, DateTime.utc_now(), :second)
    max(@refresh_floor_ms, (secs - @refresh_lead_s) * 1000)
  end

  def refresh_delay_ms(_auth), do: nil

  defp due_threshold, do: DateTime.add(DateTime.utc_now(), @refresh_lead_s, :second)

  # Call an optional callback, or return `default` when the provider omits it.
  defp optional(mod, fun, args, default) do
    Code.ensure_loaded(mod)

    if function_exported?(mod, fun, length(args)),
      do: apply(mod, fun, args),
      else: default
  end
end
