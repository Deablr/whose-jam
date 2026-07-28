defmodule WhoseJam.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WhoseJamWeb.Telemetry,
      WhoseJam.Repo,
      {DNSCluster, query: Application.get_env(:whose_jam, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WhoseJam.PubSub},
      WhoseJam.Spotify.Cache,
      # Per-game runtime: registry of live games + dynamic supervisor of servers.
      {Registry, keys: :unique, name: WhoseJam.Game.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: WhoseJam.Game.Supervisor},
      WhoseJamWeb.Presence,
      # Start to serve requests, typically the last entry
      WhoseJamWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WhoseJam.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WhoseJamWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
