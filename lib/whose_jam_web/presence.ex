defmodule WhoseJamWeb.Presence do
  @moduledoc """
  Tracks connected clients per game room.

  Player LiveViews track themselves on topic `"presence:game:" <> code` with
  their player_id as key. Whenever presences change, `handle_metas/4` pushes
  the full connected-id set into the game server, which marks absent players
  AFK (their submissions stay live per the PRD).
  """
  use Phoenix.Presence, otp_app: :whose_jam, pubsub_server: WhoseJam.PubSub

  def topic(code), do: "presence:game:" <> code

  @impl true
  def init(_opts), do: {:ok, %{}}

  def track_player(pid, code, player_id) do
    track(pid, topic(code), player_id, %{})
  end

  @impl true
  def handle_metas("presence:game:" <> code, _diff, presences, state) do
    WhoseJam.Game.presence_diff(code, Map.keys(presences))
    {:ok, state}
  end

  def handle_metas(_topic, _diff, _presences, state), do: {:ok, state}
end
