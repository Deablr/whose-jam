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

  Besides `{:game_state, view}`, the room topic carries one last message when
  a game ends (`end_game/1`, its last host screen closing — see
  `attach_host/2` — or sitting idle): `{:game_ended, reason}`, with `reason`
  one of `:host_ended`, `:host_left` or `:idle`. It is the last thing the game
  says: its process stops right after sending it.
  """

  alias WhoseJam.Content
  alias WhoseJam.Game.{Codes, Server}
  alias WhoseJam.Music

  @registry WhoseJam.Game.Registry
  @supervisor WhoseJam.Game.Supervisor

  @max_code_attempts 25

  @doc """
  Create a new game for a theme, or for several played one after another
  (a list of theme ids, in the order they are played; the same theme twice
  counts once), optionally with host setting `overrides`.

  Returns `{:ok, code}` with a freshly minted, unused room code, or
  `{:error, :theme_not_found}` if a theme does not exist (or none is given).
  """
  @spec create_game(term() | [term()], map()) :: {:ok, String.t()} | {:error, term()}
  def create_game(theme_ids, host_overrides \\ %{})

  def create_game(theme_ids, host_overrides) when is_list(theme_ids) do
    themes = theme_ids |> Enum.uniq() |> Enum.map(&fetch_theme/1)

    if themes != [] and Enum.all?(themes, &match?({:ok, _}, &1)) do
      themes = themes |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)
      start_with_free_code(themes, host_overrides, @max_code_attempts)
    else
      {:error, :theme_not_found}
    end
  end

  def create_game(theme_id, host_overrides), do: create_game([theme_id], host_overrides)

  @doc "Whether a live game is registered under `code`."
  @spec exists?(String.t()) :: boolean()
  def exists?(code), do: whereis(code) != nil

  @doc "The shared public view for `code`, or `nil` if no such game."
  @spec get_state(String.t()) :: map() | nil
  def get_state(code), do: read(code, :get_state)

  @doc """
  Host-scoped view for `code`: the public view plus `:music_auth`, the host's
  music-service auth held in state (including any access token). `nil` if no
  such game.
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

  The name is kept trimmed, its whitespace runs made single spaces, and cut to
  the room's `name_max_length` setting; a name with nothing left is
  `{:error, :invalid_name}`.
  """
  @spec join(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def join(code, name), do: command(code, {:join, name})

  @doc """
  Restore a device to its existing player/audience slot in `code` (device-token
  rejoin). `{:ok, %{player_id, role}}` or `{:error, :unknown_player}`.
  """
  @spec rejoin(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rejoin(code, player_id), do: command(code, {:rejoin, player_id})

  @doc """
  A player (or audience member) leaves the game, until it is finished
  (`{:error, :finished}` after). The room topic first carries
  `{:participant_removed, player_id, :left}`; then the game carries on
  without them: their songs still to come are dropped, and they are no longer
  a choice in the rounds to come.
  """
  @spec leave(String.t(), String.t()) :: :ok | {:error, term()}
  def leave(code, player_id), do: command(code, {:remove, player_id, :left})

  @doc """
  The host removes a player (or audience member), as `leave/2` does, with
  `{:participant_removed, player_id, :removed}` on the room topic.
  """
  @spec remove_player(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_player(code, player_id), do: command(code, {:remove, player_id, :removed})

  @doc "Apply host setting `overrides` (lobby only)."
  @spec set_config(String.t(), map()) :: :ok | {:error, term()}
  def set_config(code, overrides), do: command(code, {:set_config, overrides})

  @doc """
  Store the host's music-service auth: `provider_id` (an enabled
  `WhoseJam.Music.Provider` id) and the provider-specific `auth` map returned
  by that provider's `connect/1`. Re-calling with the same provider (a token
  refresh) is always allowed; switching provider is lobby-only. Errors:
  `:unknown_provider`, `:not_lobby`.
  """
  @spec set_music(String.t(), atom() | String.t(), map()) :: :ok | {:error, term()}
  def set_music(code, provider_id, auth), do: command(code, {:set_music, provider_id, auth})

  @doc """
  Search the room's music service for songs matching `query` (what players do
  while answering). `{:ok, [track]}`, or `{:error, :not_configured}`,
  `{:error, :no_music}` (the host hasn't connected a service), `{:error, :not_found}`
  (no such game) or a provider error.
  """
  @spec search_songs(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def search_songs(code, query) do
    case host_state(code) do
      nil -> {:error, :not_found}
      %{music: nil} -> {:error, :no_music}
      %{music: %{id: provider}, music_auth: auth} -> Music.search(provider, query, auth)
    end
  end

  @doc """
  Start the game. Requires at least `min_players` players (a host setting,
  default three) and a connected music service whose account is eligible to
  play full songs. Errors: `:not_enough_players`, `:not_authenticated`,
  `:not_eligible`, `:already_started`.
  """
  @spec start_game(String.t()) :: :ok | {:error, term()}
  def start_game(code), do: command(code, :start_game)

  @doc """
  Start the game on behalf of `player_id`, a player the host made a host
  (`set_phone_host/3`). The same checks as `start_game/1`, and
  `{:error, :not_host}` for anyone else.
  """
  @spec start_game(String.t(), String.t()) :: :ok | {:error, term()}
  def start_game(code, player_id), do: command(code, {:start_game, player_id})

  @doc """
  Host action (lobby only): let `player_id` start the game from their phone
  (`host?` true), or take that back. Only a player can be one:
  `{:error, :unknown_player}` for an audience member or a stranger.
  """
  @spec set_phone_host(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_phone_host(code, player_id, host?),
    do: command(code, {:set_phone_host, player_id, host?})

  @doc """
  Host action (lobby only): the song the TV plays under the lobby and the
  song-picking, or `nil` for none. `song` is validated like a submitted song
  (`submit_song/4`), against the room's music service.
  Errors: `:no_music`, `:invalid_song`, `:not_lobby`. Connecting a service
  already picks that service's default (`WhoseJam.Music.default_background/1`).
  """
  @spec set_background(String.t(), map() | nil) :: :ok | {:error, term()}
  def set_background(code, song), do: command(code, {:set_background, song})

  @doc """
  Submit (or re-submit, until the answer timer ends) a song for `question_id`.
  `song` is `%{uri, name, artist, album_art_url}`. `uri` must be a well-formed
  song URI of the room's music provider (e.g. `spotify:track:<22 alphanumerics>`),
  otherwise the submission is rejected with `{:error, :invalid_song}`.
  `name`/`artist` are trimmed and capped at 200 characters (non-strings become
  `""`). `album_art_url` is kept only if the provider recognizes it as its own
  art host (e.g. `https://i.scdn.co/image/<id>`); anything else is stored as
  `nil`. See `WhoseJam.Music.Track`.
  """
  @spec submit_song(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def submit_song(code, player_id, question_id, song),
    do: command(code, {:submit_song, player_id, question_id, song})

  @doc """
  Cast a vote in the current round. From the round's submitter the choice is
  not a vote but their forecast of the wrong answer the room will fall for,
  or, naming themselves, that nobody will (worth a point if it comes true). Rejects a choice the round doesn't offer
  and double votes (unless `allow_vote_change?` is enabled).
  """
  @spec cast_vote(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def cast_vote(code, voter_id, choice), do: command(code, {:cast_vote, voter_id, choice})

  @doc """
  Give the song in play another second, from someone who has locked in,
  once the vote's countdown is running (`{:error, :no_countdown}` before,
  `{:error, :not_locked_in}` from anyone else). There is no limit, but taps
  closer together than a moment count once (`{:error, :too_fast}`).
  """
  @spec extend_song(String.t(), String.t()) :: :ok | {:error, term()}
  def extend_song(code, player_id), do: command(code, {:extend_song, player_id})

  @doc """
  A winner of a finished game picks one of their own songs that was played,
  by its uri, to play the night out. The first pick stands
  (`{:error, :already_picked}` after it); `{:error, :not_winner}` from anyone
  else, `{:error, :not_played}` for a song that wasn't theirs or wasn't
  played. The public view then carries `finale: %{player_id, song}`.
  """
  @spec pick_finale(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def pick_finale(code, player_id, uri), do: command(code, {:pick_finale, player_id, uri})

  @doc """
  Keep the link to the playlist the host saved of a finished game's songs
  (see `WhoseJam.Music.save_playlist/4`), so every screen can offer it: the
  public view carries it as `saved_playlist`. Only an `https://` link of a
  finished game (`{:error, :bad_link}`, `{:error, :not_finished}`).
  """
  @spec set_saved_playlist(String.t(), String.t()) :: :ok | {:error, term()}
  def set_saved_playlist(code, url), do: command(code, {:set_saved_playlist, url})

  @doc """
  Save a finished game's songs, in the order played, as a playlist in the
  host's account with the room's music service (`WhoseJam.Music.save_playlist/4`;
  `params` are a playlist sign-in's callback params, or `%{}` for a service
  without one), and keep its link (`set_saved_playlist/2`). The music service
  is called from the caller's process, never the game's. Returns the link.
  Once one is saved, it is the link: the service isn't asked again (each
  save spends its quota, and anyone with the room code can ask).
  """
  @spec save_playlist(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def save_playlist(code, params) when is_map(params) do
    case get_state(code) do
      %{phase: :finished, saved_playlist: "https://" <> _ = url} -> {:ok, url}
      view -> save_new_playlist(code, view, params)
    end
  end

  defp save_new_playlist(code, view, params) do
    with %{phase: :finished, music: %{id: provider_id}, playlist: [_ | _] = songs} <-
           view || {:error, :not_found},
         {:ok, mod} <- Music.fetch_provider(provider_id) |> ok_or(:unknown_provider),
         {:ok, url} <-
           Music.save_playlist(mod, params, playlist_name(), Enum.map(songs, & &1.uri)),
         :ok <- set_saved_playlist(code, url) do
      {:ok, url}
    else
      {:error, _reason} = error -> error
      _not_finished -> {:error, :not_finished}
    end
  end

  defp ok_or({:ok, _} = ok, _reason), do: ok
  defp ok_or(:error, reason), do: {:error, reason}

  defp playlist_name, do: "Whose Jam, " <> Calendar.strftime(Date.utc_today(), "%B %-d")

  @doc "Host action: skip past the current round."
  @spec skip_song(String.t()) :: :ok | {:error, term()}
  def skip_song(code), do: command(code, :skip_song)

  @doc """
  Host-screen playback finished. During the listening delay (`:revealing`) this
  opens voting early; in `:revealing` or `:voting` it starts the vote countdown
  if it isn't already running (a running countdown is left unchanged). Any
  other state returns `{:error, :not_playing}`.

  `uri` is the song that ended, when the screen knows it: a report about
  any song but the one the round has playing (one the round has since moved
  on from) is ignored, and answers `:ok`.
  """
  @spec song_ended(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def song_ended(code, uri \\ nil), do: command(code, {:song_ended, uri})

  @doc "Reset a finished game back to the lobby, keeping the player roster."
  @spec play_again(String.t()) :: :ok | {:error, term()}
  def play_again(code), do: command(code, :play_again)

  @doc """
  Host action: end the game for everyone now. The server broadcasts
  `{:game_ended, :host_ended}` on the room topic and stops; nothing is kept.
  """
  @spec end_game(String.t()) :: :ok | {:error, term()}
  def end_game(code), do: command(code, :end_game)

  @doc """
  Count `pid` (a host screen's LiveView process) as an open host screen of
  `code` for as long as it lives.

  The game lasts while a host screen is open. When the last one closes and
  none attaches again within 30 seconds, the game ends: the server broadcasts
  `{:game_ended, :host_left}` and stops. A game no host screen has attached to
  yet is never ended this way.
  """
  @spec attach_host(String.t(), pid()) :: :ok | {:error, term()}
  def attach_host(code, pid), do: command(code, {:attach_host, pid})

  @doc """
  The host screen of `code` is leaving for a music service's sign-in page
  (the OAuth redirect). Until that sign-in comes back
  (`host_back_from_sign_in/2`), or 15 minutes at most, the game waits that
  long for a host screen to come back instead of 30 seconds, so connecting a
  music service never ends the game.

  Returns `{:ok, sign_in_id}`, the id the OAuth callback hands back.
  Honoured while a host screen is open, as it normally still is (Connect is a
  plain link, so the page stays connected until the provider's page loads), or
  within the 30-second grace after the last one closed, for a screen that
  dropped just before. Any other time the notice can't be a host's:
  `{:error, :no_host_screen}`. At most four sign-ins are under way at once
  (`{:error, :too_many_sign_ins}`).

  A sign-in to save a finished game's playlist (`purpose` `:playlist`) also
  keeps the finished game up while it is under way.
  """
  @spec host_signing_in(String.t(), :connect | :playlist) ::
          {:ok, String.t()} | {:error, term()}
  def host_signing_in(code, purpose \\ :connect) when purpose in [:connect, :playlist],
    do: command(code, {:host_signing_in, purpose})

  @doc """
  The sign-in `sign_in_id` (from `host_signing_in/2`) is over, whatever its
  outcome: the OAuth callback came back. Once no sign-in is under way, the
  usual 30-second grace applies again. Only an id that was let in and is
  still under way counts, and only once: `{:error, :unknown_sign_in}`
  otherwise.
  """
  @spec host_back_from_sign_in(String.t(), String.t()) :: :ok | {:error, term()}
  def host_back_from_sign_in(code, sign_in_id),
    do: command(code, {:host_back_from_sign_in, sign_in_id})

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

  defp start_with_free_code(_themes, _overrides, 0), do: {:error, :code_exhausted}

  defp start_with_free_code(themes, overrides, attempts) do
    code = Codes.generate()

    spec = {Server, code: code, themes: themes, overrides: overrides}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, _pid} -> {:ok, code}
      {:error, {:already_started, _pid}} -> start_with_free_code(themes, overrides, attempts - 1)
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
