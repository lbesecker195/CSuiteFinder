defmodule CsuiteFinderWeb.SeatCheckoutTest do
  @moduledoc """
  The $999 CTA, which is one click from a marketing page to a payment page.

  No account, no form, no login in between — Checkout collects the address and
  the account is opened from it once the money has actually moved.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  describe "the seat CTA" do
    test "points at the seat checkout, whichever gateway is live", %{conn: conn} do
      # No processor's domain is hardcoded here any more. Three have come and
      # gone in this codebase, and a baked-in URL outlives the account it
      # belongs to — /checkout/seat builds a link against whatever is actually
      # configured. Set :payment_links to a static URL to override it.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ ~s|href="/checkout/seat"|
      refute html =~ ~s|href="/checkout?plan=seat"|
    end

    test "and there is one of those buttons everywhere a price is quoted",
         %{conn: conn} do
      html = conn |> get(~p"/teams") |> html_response(200)

      count =
        ~r|href="/checkout/seat"|
        |> Regex.scan(html)
        |> length()

      assert count >= 3,
             "only #{count} seat CTAs; the hero, the rolodex and the pricing " <>
               "card should each have one"
    end
  end

  describe "the /checkout/seat route, which is still there behind it" do
    test "falls back to the form rather than dead-ending", %{conn: conn} do
      # Kept as a server-side path for anything that needs per-visit metadata a
      # static link cannot carry. Stripe has no secret key in test, so this is
      # the failure path: the page that takes the money must not show an error.
      conn = get(conn, ~p"/checkout/seat")

      assert redirected_to(conn) == "/checkout?plan=seat"
    end

    test "whatever the parameters say", %{conn: conn} do
      conn = get(conn, ~p"/checkout/seat?interval=year&seats=3&email=jane@acme.com")

      assert redirected_to(conn) == "/checkout?plan=seat"
    end
  end
end
