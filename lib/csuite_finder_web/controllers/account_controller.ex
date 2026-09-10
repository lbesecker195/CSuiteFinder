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

  alias CsuiteFinder.Billing.{Plans, Pricing}

  require EEx

  @template Path.join(:code.priv_dir(:csuite_finder), "templates/account.html.eex")
  @external_resource @template

  EEx.function_from_file(:defp, :render_account, @template, [:assigns])

  @doc """
  GET /account

  Accepts `?email=` so a campaign link can arrive with the signup field already
  filled in. See `prefill_email/1` for why that parameter is not simply printed.
  """
  def index(conn, params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      render_account(Map.put(assigns(), :prefill_email, prefill_email(params["email"])))
    )
  end

  @doc "The address to put in the signup field, or an empty string."
  @spec prefill_email(term()) :: String.t()
  def prefill_email(value), do: CsuiteFinderWeb.Prefill.email(value) || ""

  defp assigns do
    %{
      minimum_usd_label: delimit(Pricing.min_bundle_usd()),
      trial_price: :erlang.float_to_binary(Pricing.trial_usd(), decimals: 2),
      trial_months: Pricing.trial_months(),
      min_password: CsuiteFinder.Accounts.min_password_length(),
      seat_usd: Plans.seat_usd(),
      seat_usd_label: delimit(Plans.seat_usd()),
      email_price:
        :erlang.float_to_binary(Pricing.price_usd("email.find"), [:compact, decimals: 4]),
      bundles:
        for b <- Pricing.bundles() do
          %{
            usd: b.usd,
            usd_label: delimit(b.usd),
            emails_label: delimit(b.emails)
          }
        end
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
