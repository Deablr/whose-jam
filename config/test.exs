import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :whose_jam, WhoseJam.Repo,
  username: "postgres",
  password: "password",
  hostname: "localhost",
  database: "whose_jam_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :whose_jam, WhoseJamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IbzpjAln+WerqxcV8yYVhLBTjqOPASTgXi1eXEQq6K3nmgG04Fir2dqwvvyZigqa",
  server: false

# In test we don't send emails
config :whose_jam, WhoseJam.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Shorten the per-round reveal/results pause so game tests run fast.
config :whose_jam, results_pause_ms: 10

# Every provider is enabled so the shared provider contract tests cover them.
config :whose_jam, :music_providers, [
  WhoseJam.Music.Providers.Spotify,
  WhoseJam.Music.Providers.Mock
]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
