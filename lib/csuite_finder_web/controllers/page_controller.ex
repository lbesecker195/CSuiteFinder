defmodule CsuiteFinderWeb.PageController do
  @moduledoc """
  The landing page, and the same commercial terms as JSON.

  The page is rendered from `priv/templates/landing.html.eex` with the *live*
  pricing constants rather than numbers typed into markup — a price change moves
  the page and the invoice together, which is the only way they stay in step.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Billing.{Plans, Pricing}
  alias CsuiteFinderWeb.SampleSheet

  require EEx

  @template Path.join(:code.priv_dir(:csuite_finder), "templates/landing.html.eex")
  @external_resource @template

  EEx.function_from_file(:defp, :render_landing, @template, [:assigns])

  @teams_template Path.join(:code.priv_dir(:csuite_finder), "templates/teams.html.eex")
  @external_resource @teams_template

  EEx.function_from_file(:defp, :render_teams, @teams_template, [:assigns])

  @developers_template Path.join(:code.priv_dir(:csuite_finder), "templates/developers.html.eex")
  @external_resource @developers_template

  EEx.function_from_file(:defp, :render_developers, @developers_template, [:assigns])

  @start_template Path.join(:code.priv_dir(:csuite_finder), "templates/start.html.eex")
  @external_resource @start_template

  EEx.function_from_file(:defp, :render_start, @start_template, [:assigns])

  @llms_template Path.join(:code.priv_dir(:csuite_finder), "templates/llms.txt.eex")
  @external_resource @llms_template

  EEx.function_from_file(:defp, :render_llms, @llms_template, [:assigns])

  @doc "GET /"
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render_landing(assigns(conn)))
  end

  @doc "GET /teams — the seat plan, for people who buy a tool rather than an API."
  def teams(conn, _params) do
    seat = Plans.seat()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      render_teams(
        Map.merge(assigns(conn), %{
          seat_usd: delimit(seat.usd_per_month),
          seat_includes: seat.includes,
          seat_caveats: seat.caveats,
          seat_emails: delimit(seat.lookups.emails),
          comparison: Plans.comparison(),
          contact_email: contact_email()
        })
      )
    )
  end

  @doc "GET /developers — the API, its prices and its reference."
  def developers(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      render_developers(Map.put(assigns(conn), :comparison, Plans.comparison()))
    )
  end

  defp contact_email do
    Application.get_env(:csuite_finder, :contact_email, "sales@csuitefinder.com")
  end

  @doc "GET /start"
  def start(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render_start(assigns(conn)))
  end

  @doc """
  GET /llms.txt

  The agent-facing description of this API, generated from the same pricing the
  invoice uses — so an agent reading it is quoted what it will actually be
  charged. Served as text/plain so it renders in a terminal and a browser alike.
  """
  def llms(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, render_llms(assigns(conn)))
  end

  @doc """
  GET /csuitefinder/pricing

  Documented in `llms.txt` and reached by code, so it answers with the
  developer terms unless asked otherwise — the caller here is by definition
  someone reading an API.
  """
  def pricing(conn, params),
    do: json(conn, Pricing.terms(params["audience"] || "developer"))

  defp assigns(conn) do
    %{
      base_url: base_url(conn),
      seat_usd: delimit(Plans.seat_usd()),
      email_price: format(Pricing.price_usd("email.find")),
      phone_price: format(Pricing.price_usd("phone.find")),
      min_bundle: delimit(Pricing.min_bundle_usd()),
      sheet: SampleSheet.rows(),
      sheet_date: Calendar.strftime(SampleSheet.generated_on(), "%-d %B %Y"),
      # The row count in the sheet's status bar is the seat's monthly credit at
      # the price of a work email — the same arithmetic the plan is built on,
      # not a number typed into markup.
      sheet_rows: delimit(Plans.seat_lookups().emails),
      trial_usd: "$" <> format(Pricing.trial_usd()),
      trial_months: Pricing.trial_months(),
      bundles:
        for b <- Pricing.bundles() do
          %{
            usd: delimit(b.usd),
            emails: delimit(b.emails),
            phones: delimit(b.phones)
          }
        end,
      price_rows:
        Pricing.list_usd()
        |> Enum.sort_by(fn {endpoint, _} -> endpoint end)
        |> Enum.map(fn {endpoint, usd} -> {endpoint, usd, format(usd)} end)
    }
  end

  defp base_url(conn) do
    case Application.get_env(:csuite_finder, :public_base_url) do
      nil -> "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
      configured -> configured
    end
  end

  defp port_suffix(%{scheme: :http, port: 80}), do: ""
  defp port_suffix(%{scheme: :https, port: 443}), do: ""
  defp port_suffix(%{port: port}), do: ":#{port}"

  # Trailing zeros make a price list hard to scan; "0.0025" and "0.01" should
  # each render as written rather than padded to a fixed width.
  defp format(number) when is_float(number) do
    number
    |> :erlang.float_to_binary([:compact, decimals: 6])
    |> String.replace(~r/(\.\d*?)0+$/, "\\1")
    |> String.replace_suffix(".", "")
  end

  defp delimit(integer) do
    integer
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
