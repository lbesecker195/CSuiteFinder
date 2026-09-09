defmodule CsuiteFinderWeb.PageController do
  @moduledoc """
  The landing page, and the same commercial terms as JSON.

  The page is rendered from `priv/templates/landing.html.eex` with the *live*
  pricing constants rather than numbers typed into markup — a price change moves
  the page and the invoice together, which is the only way they stay in step.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Billing.Pricing

  require EEx

  @template Path.join(:code.priv_dir(:csuite_finder), "templates/landing.html.eex")
  @external_resource @template

  EEx.function_from_file(:defp, :render_landing, @template, [:assigns])

  @doc "GET /"
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render_landing(assigns(conn)))
  end

  @doc "GET /csuitefinder/pricing"
  def pricing(conn, _params), do: json(conn, Pricing.terms())

  defp assigns(conn) do
    prices = Pricing.list()

    %{
      base_url: base_url(conn),
      token_price: format(Pricing.token_price_usd()),
      min_bundle: delimit(Pricing.min_bundle_usd()),
      min_bundle_tokens: delimit(Pricing.tokens_for_usd(Pricing.min_bundle_usd())),
      trial_tokens: Pricing.trial_tokens(),
      trial_usd: "$" <> format(Pricing.usd_for_tokens(Pricing.trial_tokens())),
      price_rows:
        prices
        |> Enum.sort_by(fn {endpoint, _} -> endpoint end)
        |> Enum.map(fn {endpoint, tokens} ->
          {endpoint, tokens, format(Pricing.usd_for_tokens(tokens))}
        end)
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
