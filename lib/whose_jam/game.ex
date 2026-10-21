defmodule WhoseJam.Game do
  @moduledoc """
  Public facade for the game runtime.

  This is the *only* module LiveViews call. It hides the process topology
  (`Registry` + `DynamicSupervisor` + one `WhoseJam.Game.Server` per game)
  behind a flat set of functions: create a game, look one up, and drive it with
  events. Every read returns the plain public-view map (see
  `WhoseJam.Game.Server.public_view/1`); every command returns `:ok` or
  `{:error, reason}`.

  Callers never need to know a game's pid or hold a reference — everything is
  addressed by room code. When a code has no live game, reads return `nil` and
  commands return `{:error, :not_found}`.
  """

  alias WhoseJam.Content
  alias WhoseJam.Game.{Codes, Server}

  @registry WhoseJam.Game.Registry
  @supervisor WhoseJam.Game.Supervisor

  @max_code_attempts 25

  @doc """
  Create a new game for `theme_id`, optionally with host setting `overrides`.

  Returns `{:ok, code}` with a freshly minted, unused room code, or
  `{:error, :theme_not_found}` if the theme does not exist.
  """
  @spec create_game(term(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_game(theme_id, host_overrides \\ %{}) do
    case fetch_theme(theme_id) do
      {:ok, theme} -> start_with_free_code(theme, host_overrides, @max_code_attempts)
      :error -> {:error, :theme_not_found}
    end
  end

  @doc "Whether a live game is registered under `code`."
  @spec exists?(String.t()) :: boolean()
  def exists?(code), do: whereis(code) != nil

  @doc "The shared public view for `code`, or `nil` if no such game."
  @spec get_state(String.t()) :: map() | nil
  def get_state(code), do: read(code, :get_state)

  @doc """
  Host-scoped view for `code`: the public view plus the Spotify auth held in
  state (including the access token). `nil` if no such game.
  """
  @spec host_state(String.t()) :: map() | nil
  def host_state(code), do: read(code, :host_state)

  @doc """
  Player-scoped view for `code`: the public view plus `:me`, this player's own
  assigned questions and submissions. `nil` if no such game.
  """
  @spec player_view(String.t(), String.t()) :: map() | nil
  def player_view(code, player_id), do: read(code, {:player_view, player_id})

  @doc """
  Join `code` under display `name`.

  Returns `{:ok, %{player_id: id, role: role}}`. The role is `:player` for the
  first eight joiners while still in the lobby; anyone past that, or anyone
  joining after the game has started, becomes `:audience`. When the audience
  soft cap (~20) is exceeded the result also carries
  `audience_soft_cap_exceeded: true` — a friendly indicator, never a rejection.
  """
  @spec join(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def join(code, name), do: command(code, {:join, name})

  @doc """
  Restore a device to its existing player/audience slot in `code` (device-token
  rejoin). `{:ok, %{player_id, role}}` or `{:error, :unknown_player}`.
  """
  @spec rejoin(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rejoin(code, player_id), do: command(code, {:rejoin, player_id})

  @doc "Apply host setting `overrides` (lobby only)."
  @spec set_config(String.t(), map()) :: :ok | {:error, term()}
  def set_config(code, overrides), do: command(code, {:set_config, overrides})

  @doc """
  Store the host's Spotify auth result in state. Expects a map with
  `:access_token`, `:refresh_token`, `:expires_at`, and `:premium?`.
  """
  @spec set_spotify(String.t(), map()) :: :ok | {:error, term()}
  def set_spotify(code, spotify), do: command(code, {:set_spotify, spotify})

  @doc """
  Start the game. Requires at least `min_players` players (a host setting,
  default three) and a Premium-verified Spotify auth. Errors: `:not_enough_players`, `:not_authenticated`, `:not_premium`,
  `:already_started`.
  """
  @spec start_game(String.t()) :: :ok | {:error, term()}
  def start_game(code), do: command(code, :start_game)

  @doc """
  Submit (or re-submit, until the answer timer ends) a song for `question_id`.
  `song` is `%{uri, name, artist, album_art_url}`. `album_art_url` is kept only
  if it is a Spotify image-CDN URL (`https://i.scdn.co/image/<id>`); anything
  else is stored as `nil`.
  """
  @spec submit_song(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def submit_song(code, player_id, question_id, song),
    do: command(code, {:submit_song, player_id, question_id, song})

  @doc """
  Cast a vote in the current round. Rejects the submitter voting on their own
  round and double votes (unless `allow_vote_change?` is enabled).
  """
  @spec cast_vote(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def cast_vote(code, voter_id, choice), do: command(code, {:cast_vote, voter_id, choice})

  @doc "Host action: skip past the current round."
  @spec skip_song(String.t()) :: :ok | {:error, term()}
  def skip_song(code), do: command(code, :skip_song)

  @doc """
  Host-screen playback finished. During the listening delay (`:revealing`) this
  opens voting early; in `:revealing` or `:voting` it starts the vote countdown
  if it isn't already running (a running countdown is left unchanged). Any
  other state returns `{:error, :not_playing}`.
  """
  @spec song_ended(String.t()) :: :ok | {:error, term()}
  def song_ended(code), do: command(code, :song_ended)

  @doc "Reset a finished game back to the lobby, keeping the player roster."
  @spec play_again(String.t()) :: :ok | {:error, term()}
  def play_again(code), do: command(code, :play_again)

  @doc """
  Inform the server which participant ids are currently connected (LiveViews
  wire this from `Phoenix.Presence`). Absent ids are marked disconnected/AFK.
  """
  @spec presence_diff(String.t(), [String.t()]) :: :ok | {:error, term()}
  def presence_diff(code, connected_ids), do: command(code, {:presence_diff, connected_ids})

  # =========================================================================
  # Internals
  # =========================================================================

  defp fetch_theme(theme_id) do
    {:ok, Content.get_theme!(theme_id)}
  rescue
    Ecto.NoResultsError -> :error
    Ecto.Query.CastError -> :error
    ArgumentError -> :error
  end

  defp start_with_free_code(_theme, _overrides, 0), do: {:error, :code_exhausted}

  defp start_with_free_code(theme, overrides, attempts) do
    code = Codes.generate()

    spec = {Server, code: code, theme: theme, overrides: overrides}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, _pid} -> {:ok, code}
      {:error, {:already_started, _pid}} -> start_with_free_code(theme, overrides, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp whereis(code) do
    case Registry.lookup(@registry, code) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp read(code, msg) do
    case whereis(code) do
      nil -> nil
      pid -> safe_call(pid, msg, nil)
    end
  end

  defp command(code, msg) do
    case whereis(code) do
      nil -> {:error, :not_found}
      pid -> safe_call(pid, msg, {:error, :not_found})
    end
  end

  defp safe_call(pid, msg, on_dead) do
    GenServer.call(pid, msg)
  catch
    :exit, _ -> on_dead
  end
end
