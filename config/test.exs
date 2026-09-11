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

# The model fallback is answered by a plug in-process; tests that want it opt in
# by stubbing, and everything else sees it as switched off.
config :csuite_finder, CsuiteFinder.Inference,
  base_url: "http://inference.test",
  api_key: nil,
  plug: CsuiteFinder.InferenceStub

# Exercise the real auth path in tests.
config :csuite_finder, :require_api_key, true

# Deterministic in tests, so assertions about printed URLs do not depend on
# whatever host Phoenix.ConnTest happens to synthesise.
config :csuite_finder, :public_base_url, "https://csuitefinder.test"

# No analytics from test: this traffic is ours and would distort the numbers.
config :csuite_finder, :ga_measurement_id, nil

# Stripe is switched off in tests unless a test stubs it: a suite that can reach
# a payment processor is a suite that will eventually charge somebody.
config :csuite_finder, CsuiteFinder.Billing.Stripe,
  secret_key: nil,
  webhook_secret: "whsec_test_secret",
  seat_price_id: "price_test_monthly",
  seat_annual_price_id: "price_test_annual"

# Square is switched off in tests unless one stubs it; the signature key is set
# so the webhook verification tests have something to verify against.
config :csuite_finder, CsuiteFinder.Billing.Square,
  access_token: nil,
  signature_key: "square_test_signature_key",
  location_id: "L_TEST",
  notification_url: "https://csuitefinder.test/csuitefinder/billing/webhook",
  seat_plan_id: "VAR_MONTHLY_TEST",
  seat_annual_plan_id: "VAR_ANNUAL_TEST"

# No pings from the suite: a test run must never reach a third party, and a uid
# here would send one on every settle.
config :csuite_finder, CsuiteFinder.Ssa, uid: nil
