import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :csuite_finder, CsuiteFinder.Repo,
  username: System.get_env("PGUSER") || "logan",
  password: System.get_env("PGPASSWORD") || "",
  hostname: "localhost",
  database: "csuite_finder_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :csuite_finder, CsuiteFinderWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "yS/EshmdiCdQYdlJDF9NAXl1ibQxi3vF9DqPL8mGMbgbq7OpaTL/s0+QBWKjOjyf",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests never reach the network: treg calls are served by a plug in-process.
config :csuite_finder, CsuiteFinder.Treg.Client,
  base_url: "http://treg.test",
  token: "test-token",
  plug: CsuiteFinder.TregStub

# Exercise the real auth path in tests.
config :csuite_finder, :require_api_key, true
