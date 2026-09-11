defmodule CsuiteFinder.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CsuiteFinderWeb.Telemetry,
      CsuiteFinder.Repo,
      {DNSCluster, query: Application.get_env(:csuite_finder, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CsuiteFinder.PubSub},
      # Hands annual seats their monthly credit. Safe to run on every node —
      # see CsuiteFinder.Billing.SeatRefresher.
      CsuiteFinder.Billing.SeatRefresher,
      # Batches agent-side usage into one ping every ten seconds.
      CsuiteFinder.Ssa.Throttle,
      # Start a worker by calling: CsuiteFinder.Worker.start_link(arg)
      # {CsuiteFinder.Worker, arg},
      # Start to serve requests, typically the last entry
      CsuiteFinderWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CsuiteFinder.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CsuiteFinderWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
