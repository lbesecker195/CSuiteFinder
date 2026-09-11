defmodule CsuiteFinderWeb.SeatCheckoutTest do
  @moduledoc """
  The $999 CTA, which is one click from a marketing page to a payment page.

  No account, no form, no login in between — Checkout collects the address and
  the account is opened from it once the money has actually moved.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  describe "the seat CTA" do
    test "goes straight to Stripe, on Stripe's own domain", %{conn: conn} do
      # A static Payment Link rather than a route of ours. The button on a
      # marketing page then does not depend on this application being reachable
      # at the moment somebody clicks it — which is most of the point.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ ~s|href="https://buy.stripe.com/|
      refute html =~ ~s|href="/checkout?plan=seat"|
    end

    test "and there is one of those buttons everywhere a price is quoted",
         %{conn: conn} do
      html = conn |> get(~p"/teams") |> html_response(200)

      links =
        Regex.scan(~r|href="(https://buy\.stripe\.com/[^"]+)"|, html, capture: :all_but_first)

      assert length(links) >= 3,
             "only #{length(links)} seat CTAs reach Stripe; the hero, the rolodex " <>
               "and the pricing card should each have one"
    end

    test "and the trial CTA still goes to the chooser", %{conn: conn} do
      # Someone who clicked a $29.99 trial has not decided yet, so they get the
      # page with both prices on it. Only the seat skips straight to paying.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ ~s|href="/checkout"|
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
