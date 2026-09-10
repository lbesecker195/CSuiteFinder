defmodule CsuiteFinderWeb.HealthController do
  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Repo

  def index(conn, _params) do
    db_ok =
      case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
        {:ok, _} -> true
        _ -> false
      end

    status = if db_ok, do: :ok, else: :service_unavailable

    conn
    |> put_status(status)
    |> json(%{
      status: if(db_ok, do: "ok", else: "degraded"),
      database: db_ok,
      # Deliberately generic: a health check should not name our suppliers.
      lookups_configured: CsuiteFinder.Treg.Client.configured?(),
      payments_configured: CsuiteFinder.Billing.PayPal.configured?(),
      # Split out because these two fail silently. A missing webhook id drops
      # every callback PayPal retries, and sandbox credentials look identical
      # to live ones until someone tries to pay.
      payments_webhooks_configured: CsuiteFinder.Billing.PayPal.webhooks_configured?(),
      payments_mode: CsuiteFinder.Billing.PayPal.mode(),
      version: Application.spec(:csuite_finder, :vsn) |> to_string()
    })
  end
end
