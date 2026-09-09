defmodule CsuiteFinderWeb.AccountController do
  @moduledoc """
  The account page: register, check a balance, and buy tokens from a browser.

  The API is key-authenticated, and a browser cannot put a bearer header on a
  plain navigation — which is exactly the friction this page removes. The key
  lives in the visitor's own `localStorage` and every call is `fetch` with the
  header attached, so the server stays a pure API and no session, cookie or
  second auth path is introduced for the sake of the UI.

  Rendered from `priv/templates/account.html.eex` with the live pricing
  constants, for the same reason the landing page is: a price change moves the
  page and the invoice together.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Billing.Pricing

  require EEx

  @template Path.join(:code.priv_dir(:csuite_finder), "templates/account.html.eex")
  @external_resource @template

  EEx.function_from_file(:defp, :render_account, @template, [:assigns])

  @doc "GET /account"
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render_account(assigns()))
  end

  defp assigns do
    minimum = Pricing.min_bundle_usd()
    per_find = Pricing.charge_for("email.find")

    # Offered bundles. The first is the minimum; the rest are round multiples
    # rather than invented discount tiers — the token price is flat, and a fake
    # "save 20%" on a flat rate would be a lie.
    bundles =
      for usd <- [minimum, minimum * 5, minimum * 25] do
        tokens = Pricing.tokens_for_usd(usd)

        %{
          usd: usd,
          usd_label: delimit(usd),
          tokens_label: delimit(tokens),
          finds_label: delimit(div(tokens, max(per_find, 1)))
        }
      end

    %{
      minimum_usd_label: delimit(minimum),
      token_price_label:
        :erlang.float_to_binary(Pricing.token_price_usd(), [:compact, decimals: 4]),
      trial_tokens: Pricing.trial_tokens(),
      bundles: bundles
    }
  end

  # Thousands separators. Done here rather than in the template: an EEx file
  # is markup, and a pipeline of String.reverse/replace buried in an attribute
  # is unreadable in both places at once.
  defp delimit(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
