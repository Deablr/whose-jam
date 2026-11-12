defmodule Mix.Tasks.Test.E2e do
  @shortdoc "Runs the Playwright end-to-end suite against a Postgres container"

  @moduledoc """
  Runs the browser end-to-end tests in `test/e2e/` (tagged `:e2e`).

      mix test.e2e
      mix test.e2e test/e2e/full_game_test.exs

  Nothing is mocked except the music service (the dev/test-only `Mock`
  provider). Before the tests run this task:

    1. starts a throwaway Postgres in Docker through Testcontainers (the same
       `postgres:16` image `docker-compose.yml` deploys; Ryuk removes it when
       the VM exits),
    2. points `WhoseJam.Repo` at it, runs the real migrations and
       `priv/repo/seeds.exs`,
    3. builds the JS/CSS bundles and serves the app over HTTP on
       `E2E_PORT` (default `4012`),
    4. starts the Playwright browser pool, then runs `mix test --only e2e`.

  Needs Docker, plus Playwright and its Chromium in `assets/`:

      npm --prefix assets ci
      npm --prefix assets exec -- playwright install chromium

  Extra arguments are passed to `mix test`.

  Testcontainers publishes the Postgres port (user and password `test`) and
  its Ryuk reaper on all interfaces while the suite runs; run it on a trusted
  network.
  """
  use Mix.Task

  alias Testcontainers.PostgresContainer

  @postgres_image "postgres:16"
  @default_port 4012

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    # Testcontainers logs every Docker step at :debug; hold the console to
    # the test env's log level.
    Logger.configure(level: Application.get_env(:logger, :level, :warning))
    configure_repo!(start_postgres!())
    configure_endpoint!()

    Mix.Task.run("assets.setup")
    Mix.Task.run("assets.build")
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start")
    Code.eval_file("priv/repo/seeds.exs")

    case PhoenixTest.Playwright.Supervisor.start_link() do
      {:ok, _pid} -> :ok
      {:error, reason} -> Mix.raise("Couldn't start Playwright: #{inspect(reason)}")
    end

    Application.put_env(:phoenix_test, :base_url, WhoseJamWeb.Endpoint.url())

    Mix.Task.run("test", ["--only", "e2e" | test_paths(args)])
  end

  # With no file arguments, run just the e2e directory.
  defp test_paths(args) do
    if Enum.any?(args, &String.starts_with?(&1, "test/")), do: args, else: ["test/e2e" | args]
  end

  defp start_postgres! do
    for app <- [:tesla, :hackney] do
      {:ok, _started} = Application.ensure_all_started(app)
    end

    with {:ok, _pid} <- Testcontainers.start(),
         {:ok, container} <-
           Testcontainers.start_container(
             PostgresContainer.with_image(PostgresContainer.new(), @postgres_image)
           ) do
      container
    else
      {:error, reason} ->
        Mix.raise("""
        Couldn't start the Postgres container (is Docker running?): #{inspect(reason)}
        """)
    end
  end

  defp configure_repo!(container) do
    repo_config =
      :whose_jam
      |> Application.fetch_env!(WhoseJam.Repo)
      |> Keyword.merge(PostgresContainer.connection_parameters(container))
      # A whole game takes minutes; the sandbox's default 2-minute ownership
      # would drop the test's connection mid-game.
      |> Keyword.put(:ownership_timeout, to_timeout(minute: 10))

    Application.put_env(:whose_jam, WhoseJam.Repo, repo_config, persistent: true)
  end

  defp configure_endpoint! do
    port =
      case Integer.parse(System.get_env("E2E_PORT", "")) do
        {port, ""} when port in 1..65_535 -> port
        _ -> @default_port
      end

    endpoint_config =
      :whose_jam
      |> Application.fetch_env!(WhoseJamWeb.Endpoint)
      |> Keyword.merge(server: true, http: [ip: {127, 0, 0, 1}, port: port])
      |> Keyword.put(:url, host: "localhost", port: port)

    Application.put_env(:whose_jam, WhoseJamWeb.Endpoint, endpoint_config, persistent: true)
  end
end
