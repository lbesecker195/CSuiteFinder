defmodule CsuiteFinderWeb.PageController do
  @moduledoc """
  The landing page, and the same commercial terms as JSON.

  The page is rendered from `priv/templates/landing.html.eex` with the *live*
  pricing constants rather than numbers typed into markup — a price change moves
  the page and the invoice together, which is the only way they stay in step.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Audience
  alias CsuiteFinder.Billing.{Plans, Pricing, Square, Stripe}
  alias CsuiteFinderWeb.SampleSheet

  require EEx
  require Logger

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

  @checkout_template Path.join(:code.priv_dir(:csuite_finder), "templates/checkout.html.eex")
  @external_resource @checkout_template
  EEx.function_from_file(:defp, :render_checkout, @checkout_template, [:assigns])

  @doc "GET /"
  def index(conn, params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render_landing(assigns(conn, params)))
  end

  @doc "GET /teams — the seat plan, for people who buy a tool rather than an API."
  def teams(conn, params) do
    seat = Plans.seat()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      render_teams(
        Map.merge(assigns(conn, params), %{
          seat_usd: delimit(seat.usd_per_month),
          seat_includes: seat.includes,
          seat_caveats: seat.caveats,
          seat_emails: delimit(seat.lookups.emails),
          contact_email: contact_email()
        })
      )
    )
  end

  @doc """
  GET /checkout — the one page between wanting this and paying for it.

  Two modes, because the two CTAs on the site mean different things. Someone who
  clicked a seat price has already chosen, so `?plan=seat` confirms that one
  thing and sends them to PayPal. Someone who clicked the trial has not, so
  `?plan=trial` puts both prices side by side and lets them pick — which is also
  the only place a trial buyer is ever shown the seat.

  Anything else, including no plan at all, gets the chooser. The seat is the
  narrower promise, so it is never the default.
  """
  def checkout(conn, params) do
    seat = Plans.seat()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      render_checkout(
        Map.merge(assigns(conn, params), %{
          plan: if(params["plan"] == "seat", do: :seat, else: :choose),
          # A campaign link carries the address, so the one field on this page
          # is already filled by the time they get here. Shape-checked and
          # escaped on the way in — this template escapes nothing of its own.
          prefill_email: CsuiteFinderWeb.Prefill.email(params["email"]) || "",
          seat_usd: delimit(seat.usd_per_month),
          seat_emails: delimit(seat.lookups.emails),
          contact_email: contact_email()
        })
      )
    )
  end

  @doc """
  GET /checkout/seat — straight to the payment page, no form in between.

  A plain link rather than a form post, so the CTA on a marketing page is an
  ordinary href and the buyer's first click lands them on Checkout. Nothing is
  created here but a Checkout Session: no account, no subscription, no charge.
  The account is opened from the address Stripe collects, once the payment
  actually completes — so a link scanner or a prefetch produces an abandoned
  session and nothing else, which is what makes a side effect on GET acceptable
  here.

  `?email=` is passed through when a campaign link carried one, purely to
  prefill. It is never trusted as identity: the address that opens the account
  is the one Stripe confirms was paid with.
  """
  def seat_checkout(conn, params) do
    interval = if params["interval"] == "year", do: :year, else: :month
    base = base_url(conn)

    opts = [
      email: CsuiteFinderWeb.Prefill.email(params["email"]),
      return_url: base <> "/account?bought=seat",
      cancel_url: base <> "/teams#pricing"
    ]

    creator =
      if Square.configured?(),
        do: &Square.create_seat_session/4,
        else: &Stripe.create_seat_session/4

    case creator.(nil, seats(params["seats"]), interval, opts) do
      {:ok, url, _session} ->
        redirect(conn, external: url)

      {:error, reason} ->
        # Never a dead end on the page that takes the money: fall back to the
        # form, which can still get them through by any route still working.
        Logger.warning("seat checkout unavailable: #{inspect(reason)}")
        redirect(conn, to: "/checkout?plan=seat")
    end
  end

  defp seats(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 and n <= 100 -> n
      _ -> 1
    end
  end

  @doc "GET /developers — the API, its prices and its reference."
  def developers(conn, params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      render_developers(assigns(conn, params))
    )
  end

  defp contact_email do
    Application.get_env(:csuite_finder, :contact_email, "sales@csuitefinder.com")
  end

  @doc "GET /start"
  def start(conn, params) do
    seat = Plans.seat()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      render_start(
        Map.merge(assigns(conn, params), %{
          seat_usd: delimit(seat.usd_per_month),
          seat_emails: delimit(seat.lookups.emails)
        })
      )
    )
  end

  @doc """
  GET /llms.txt

  The agent-facing description of this API, generated from the same pricing the
  invoice uses — so an agent reading it is quoted what it will actually be
  charged. Served as text/plain so it renders in a terminal and a browser alike.
  """
  def llms(conn, params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, render_llms(assigns(conn, params)))
  end

  @doc """
  GET /csuitefinder/pricing

  Documented in `llms.txt` and reached by code, so it answers with the
  developer terms unless asked otherwise — the caller here is by definition
  someone reading an API.
  """
  def pricing(conn, params),
    do: json(conn, Pricing.terms(params["audience"] || "developer"))

  defp assigns(conn, params) do
    %{
      # Carried by an emailed link so the reader finds their own row in the
      # sheet. Escaped and shape-checked on the way in — see Prefill.
      visitor:
        CsuiteFinderWeb.SampleSheet.visitor(
          CsuiteFinderWeb.Prefill.name(params["name"]),
          CsuiteFinderWeb.Prefill.email(params["email"])
        ),
      base_url: base_url(conn),
      seat_usd: delimit(Plans.seat_usd()),
      email_price: format(Pricing.price_usd("email.find")),
      phone_price: format(Pricing.price_usd("phone.find")),
      linkedin_price: format(Pricing.price_usd("email.linkedin")),
      min_bundle: delimit(Pricing.min_bundle_usd()),
      sheet: SampleSheet.rows(),
      sheet_date: Calendar.strftime(SampleSheet.generated_on(), "%-d %B %Y"),
      # The row count in the sheet's status bar is the seat's monthly credit at
      # the price of a work email — the same arithmetic the plan is built on,
      # not a number typed into markup.
      sheet_rows: delimit(Plans.seat_lookups().emails),
      trial_months: Pricing.trial_months(),
      trial_price: :erlang.float_to_binary(Pricing.trial_usd(), decimals: 2),
      # What the trial actually buys, in the unit people care about. Derived so
      # the page cannot advertise a figure the price list disagrees with.
      trial_emails: delimit(div(Pricing.trial_micro(), Pricing.charge_for("email.find"))),
      bundles:
        for b <- Pricing.bundles() do
          %{
            usd: delimit(b.usd),
            emails: delimit(b.emails),
            phones: delimit(b.phones)
          }
        end,
      # Whether to quote per-answer prices. A seat holder has a month of credit
      # and no meter to watch, so a running total next to every command reads as
      # money about to be charged — it puts them off a thing they have already
      # paid for. A developer is spending a balance per call and needs it.
      show_costs: Audience.cast(params["audience"]) == "developer",
      audience: Audience.cast(params["audience"]),
      price_groups: price_groups(),
      # Static Stripe Payment Links. The seat CTA is an ordinary href to
      # Stripe's own domain rather than a route of ours, so it does not depend
      # on this application being reachable at the moment someone clicks it.
      seat_link: payment_link(:seat),
      seat_annual_link: payment_link(:seat_annual)
    }
  end

  defp payment_link(which) do
    Application.get_env(:csuite_finder, :payment_links, [])[which] || "/checkout/seat"
  end

  # The families a reader already thinks in, dearest first inside each, because
  # what someone scans a price list for is the number that will hurt.
  #
  # `email`, `phone` and `company` are pinned in that order — they are the
  # product, and an alphabetical list buries the headline price of each family
  # among the free ones. Anything added later falls in behind them
  # alphabetically rather than needing this list edited, which is the point:
  # a new family should appear in the right shape without anyone remembering to
  # come back here.
  @pinned_families ~w(email phone company)

  # Two deliberate exceptions to price order, both about what a reader should
  # meet first.
  #
  # `email.find` leads its family whatever it costs: it is the product, and the
  # first number someone sees ought to be the one they will actually pay most
  # often. `email.linkedin` sinks to the bottom for the mirror reason — it is
  # six times dearer and answers a question most callers do not have, so leading
  # with it prices the whole family wrong in the reader's head.
  @featured ~w(email.find)
  @demoted ~w(email.linkedin)

  defp price_groups do
    Pricing.list_usd()
    |> Enum.group_by(fn {endpoint, _usd} -> family(endpoint) end)
    |> Enum.sort_by(fn {family, _rows} -> family_rank(family) end)
    |> Enum.map(fn {family, rows} ->
      %{
        family: family,
        rows:
          rows
          # Featured first, demoted last, and descending by price in between —
          # then alphabetical, so the free ones inside a family keep a
          # predictable order rather than whatever the map happened to hold.
          |> Enum.sort_by(fn {endpoint, usd} -> {row_rank(endpoint), -usd, endpoint} end)
          |> Enum.map(fn {endpoint, usd} -> {endpoint, usd, format(usd)} end)
      }
    end)
  end

  defp family(endpoint), do: endpoint |> String.split(".") |> hd()

  defp row_rank(endpoint) do
    cond do
      endpoint in @featured -> 0
      endpoint in @demoted -> 2
      true -> 1
    end
  end

  defp family_rank(family) do
    case Enum.find_index(@pinned_families, &(&1 == family)) do
      nil -> {1, family}
      index -> {0, index}
    end
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
