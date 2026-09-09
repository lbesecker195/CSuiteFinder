import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/csuite_finder start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :csuite_finder, CsuiteFinderWeb.Endpoint, server: true
end

config :csuite_finder, CsuiteFinderWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # Two ways to reach Postgres, because "I never set a password" is a normal
  # state on a fresh box:
  #
  #   * DATABASE_URL       — TCP, with a password. The usual choice.
  #   * DATABASE_SOCKET_DIR — Unix socket, using Postgres peer authentication,
  #                           which needs no password at all.
  #
  # The socket form cannot be expressed as a URL: Ecto requires a host in
  # `url:` and rejects a hostless one outright, whatever query parameters it
  # carries. So it gets its own variables rather than a URL that looks like it
  # should work and does not.
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []
  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")

  repo_config =
    case System.get_env("DATABASE_SOCKET_DIR") do
      socket_dir when is_binary(socket_dir) and socket_dir != "" ->
        [
          socket_dir: socket_dir,
          username: System.get_env("DATABASE_USER") || System.get_env("USER") || "postgres",
          database:
            System.get_env("DATABASE_NAME") ||
              raise("DATABASE_SOCKET_DIR is set, so DATABASE_NAME is required too.")
        ]

      _ ->
        database_url =
          System.get_env("DATABASE_URL") ||
            raise """
            environment variable DATABASE_URL is missing.

            Either set it to a full connection URL:

                DATABASE_URL=ecto://USER:PASSWORD@HOST/DATABASE

            or, to connect with no password over the Unix socket:

                DATABASE_SOCKET_DIR=/var/run/postgresql
                DATABASE_NAME=csuite_finder_prod
                DATABASE_USER=csuite
            """

        # Check the shape here rather than letting Ecto fail inside a supervisor.
        # A host:port pair is the natural thing to type and is not a URL, and
        # the error it produces ("host is not present", with a %URI{} dump)
        # buries the one fact that helps: what it should have looked like.
        case URI.parse(database_url) do
          %URI{scheme: scheme, host: host}
          when scheme in ~w(ecto postgres postgresql) and is_binary(host) and host != "" ->
            :ok

          _ ->
            raise """
            DATABASE_URL is not a database URL: #{inspect(database_url)}

            Expected a full connection URL, not a host and port:

                ecto://USER:PASSWORD@HOST/DATABASE

            For example:

                ecto://csuite:s3cret@localhost/csuite_finder_prod

            If the password contains @ : / or ?, percent-encode it — a raw @
            splits the URL at the wrong place and gives you this same error.

            To connect with NO password, do not use a URL at all. Ecto requires
            a host here and rejects a hostless URL even with ?socket_dir=. Use
            the Unix socket variables instead:

                DATABASE_SOCKET_DIR=/var/run/postgresql
                DATABASE_NAME=csuite_finder_prod
                DATABASE_USER=csuite
            """
        end

        [url: database_url, socket_options: maybe_ipv6]
    end

  config :csuite_finder, CsuiteFinder.Repo, [pool_size: pool_size] ++ repo_config

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :csuite_finder, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The canonical public URL, used wherever a page or llms.txt prints a URL for
  # someone to copy. Pinned rather than derived from the request's Host header:
  # that header is caller-controlled, so a request with a forged Host would
  # otherwise get documentation telling it to call some other server.
  config :csuite_finder,
         :public_base_url,
         System.get_env("PUBLIC_BASE_URL") || "https://" <> host

  # Bind to loopback by default. Behind a reverse proxy (the standard VPS
  # deployment) binding to every interface would leave port 4000 reachable
  # from the internet directly — bypassing nginx, and with it TLS, the
  # security headers and any rate limiting. Set BIND_ALL=true only on
  # platforms that terminate TLS for you and route to the container's own
  # address, such as Fly.io or a Kubernetes service.
  bind_address =
    if System.get_env("BIND_ALL") in ~w(true 1) do
      {0, 0, 0, 0, 0, 0, 0, 0}
    else
      {127, 0, 0, 1}
    end

  config :csuite_finder, CsuiteFinderWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: bind_address],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :csuite_finder, CsuiteFinderWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :csuite_finder, CsuiteFinderWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# --- treg (data provider) -------------------------------------------------
# The token is injected server-side by treg, so this process only ever holds
# the treg credential itself, never a provider's key.
config :csuite_finder, CsuiteFinder.Treg.Client,
  base_url: System.get_env("TREG_BASE_URL") || "https://treg.to",
  token: System.get_env("TREG_TOKEN"),
  org: System.get_env("TREG_ORG")

# --- PayPal ---------------------------------------------------------------
config :csuite_finder, CsuiteFinder.Billing.PayPal,
  base_url:
    System.get_env("PAYPAL_BASE_URL") ||
      if(System.get_env("PAYPAL_MODE") == "live",
        do: "https://api-m.paypal.com",
        else: "https://api-m.sandbox.paypal.com"
      ),
  client_id: System.get_env("PAYPAL_CLIENT_ID"),
  client_secret: System.get_env("PAYPAL_CLIENT_SECRET"),
  webhook_id: System.get_env("PAYPAL_WEBHOOK_ID")
