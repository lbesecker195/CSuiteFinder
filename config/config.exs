# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :csuite_finder,
  ecto_repos: [CsuiteFinder.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :csuite_finder, CsuiteFinderWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: CsuiteFinderWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CsuiteFinder.PubSub,
  live_view: [signing_salt: "mjm3sDYi"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# We send through SMTP (gen_smtp), not an HTTP API adapter, so Swoosh needs no
# HTTP client. Saying so explicitly avoids a hard dependency on hackney.
config :swoosh, :api_client, false

# Default: no real transport. config/runtime.exs promotes this to SMTP when
# the SMTP_* variables are present, so an unconfigured deployment reports
# "email is off" rather than pretending to send.
config :csuite_finder, CsuiteFinder.Mailer, adapter: Swoosh.Adapters.Local

import_config "#{config_env()}.exs"
