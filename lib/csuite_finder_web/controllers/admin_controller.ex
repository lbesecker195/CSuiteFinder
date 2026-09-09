defmodule CsuiteFinderWeb.AdminController do
  @moduledoc """
  The admin dashboard.

  Charts are server-rendered SVG rather than a charting library: the page has no
  external dependencies, renders with JavaScript disabled, and cannot break
  because a CDN moved. Geometry is computed here so the template stays markup.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.Metrics

  require EEx

  @template Path.join(:code.priv_dir(:csuite_finder), "templates/admin.html.eex")
  @external_resource @template

  EEx.function_from_file(:defp, :render_admin, @template, [:assigns])

  @windows [7, 30, 90]
  @default_window 30

  @doc "GET /admin"
  def index(conn, params) do
    days = window(params["days"])
    data = Metrics.dashboard(days)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render_admin(assigns(conn, data, params)))
  end

  @doc "GET /admin/metrics.json"
  def metrics(conn, params), do: json(conn, Metrics.dashboard(window(params["days"])))

  defp window(value) do
    case Integer.parse(to_string(value)) do
      {days, _} when days in @windows -> days
      _ -> @default_window
    end
  end

  defp assigns(conn, data, params) do
    Map.merge(data, %{
      windows: @windows,
      token: params["token"],
      base_path: conn.request_path,
      chart: chart(data.daily),
      find_price_micro: Pricing.charge_for("email.find")
    })
  end

  # --- chart geometry -------------------------------------------------------

  @chart_w 720
  @chart_h 150

  defp chart(daily) do
    max_requests = daily |> Enum.map(& &1.requests) |> Enum.max(fn -> 0 end)
    scale_max = max(max_requests, 1)
    count = max(length(daily), 1)
    slot = @chart_w / count
    bar_w = max(slot * 0.62, 1.0)

    bars =
      daily
      |> Enum.with_index()
      |> Enum.map(fn {day, index} ->
        total_h = day.requests / scale_max * @chart_h
        cached_h = if day.requests > 0, do: day.cache_hits / scale_max * @chart_h, else: 0.0

        %{
          x: Float.round(index * slot + (slot - bar_w) / 2, 2),
          width: Float.round(bar_w, 2),
          y: Float.round(@chart_h - total_h, 2),
          height: Float.round(total_h, 2),
          cached_y: Float.round(@chart_h - cached_h, 2),
          cached_height: Float.round(cached_h, 2),
          label: Calendar.strftime(day.day, "%b %-d"),
          requests: day.requests,
          cache_hits: day.cache_hits
        }
      end)

    %{
      width: @chart_w,
      height: @chart_h,
      bars: bars,
      max: max_requests,
      # Only a few labels fit; pick evenly spaced ones.
      label_every: max(div(count, 8), 1)
    }
  end

  # --- formatting -----------------------------------------------------------

  @doc false
  def pct(nil), do: "—"

  def pct(value) when is_number(value),
    do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"

  @doc "Render a duration, or an em dash when nothing was measured."
  def ms(nil), do: "—"

  def ms(value) when is_number(value) and value >= 1000,
    do: :erlang.float_to_binary(value / 1000, [:compact, decimals: 1]) <> " s"

  def ms(value) when is_number(value), do: "#{round(value)} ms"
  def ms(_), do: "—"

  @doc false
  def usd(value) when is_number(value) do
    "$" <> :erlang.float_to_binary(value / 1, decimals: 2)
  end

  @doc false
  def micro_usd(nil), do: "—"

  def micro_usd(micro) when is_number(micro) do
    "$" <> :erlang.float_to_binary(micro / 1_000_000, decimals: 4)
  end

  @doc false
  def num(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def num(value) when is_float(value), do: num(round(value))
  def num(_), do: "0"

  @doc "CSS class for a figure that is good when high, bad when negative."
  def tone(value) when is_number(value) and value < 0, do: "bad"
  def tone(value) when is_number(value) and value > 0, do: "good"
  def tone(_), do: "flat"

  @doc """
  A window link that carries the admin token through.

  This template is plain EEx, which does not escape interpolations, so anything
  reaching the markup is escaped here instead. The token can only be the correct
  one by the time the page renders — the plug rejects everything else — but a
  helper that emits raw user input is a trap for the next thing added to this
  page, and `&` in an href has to be `&amp;` regardless.
  """
  def link_to(base_path, token, days) do
    query =
      if token do
        "?days=#{days}&amp;token=#{esc(URI.encode_www_form(token))}"
      else
        "?days=#{days}"
      end

    esc(base_path) <> query
  end

  @doc "Escape a value for HTML text or an attribute."
  def esc(nil), do: ""

  def esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
