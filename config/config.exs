# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Stripe Payment Links for the seat. These are static, shareable URLs — not
# secrets — so they live here with the live links as the default and can be
# pointed elsewhere per environment. A Payment Link is served by Stripe, so the
# button on a marketing page keeps working even when this application does not.
config :csuite_finder, :payment_links,
  seat: "https://buy.stripe.com/eVqeVdbwNaim5q26AP6sw05",
  seat_annual: "https://buy.stripe.com/7sY4gzeIZ8aecSuf7l6sw06"

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
# Addresses now arrive in query strings (a campaign link's ?email=) and in
# registration bodies. Phoenix logs parameters on every request, and a log full
# of customers' email addresses is a liability nobody asked for.
config :phoenix, :filter_parameters, ["password", "email", "api_key", "token"]

config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.

import_config "#{config_env()}.exs"
