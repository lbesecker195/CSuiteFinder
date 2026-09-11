defmodule CsuiteFinderWeb.SeatCheckoutTest do
  @moduledoc """
  The $999 CTA, which is one click from a marketing page to a payment page.

  No account, no form, no login in between — Checkout collects the address and
  the account is opened from it once the money has actually moved.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  describe "the seat CTA" do
    test "is a plain link on /teams, not a form", %{conn: conn} do
      # It has to be an href: a marketing page's primary button should work with
      # scripting off, and a form post cannot be a button in a paragraph.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ ~s|href="/checkout/seat"|
      refute html =~ ~s|href="/checkout?plan=seat"|
    end

    test "and the trial CTA still goes to the chooser", %{conn: conn} do
      # Someone who clicked a $29.99 trial has not decided yet, so they get the
      # page with both prices on it. Only the seat skips straight to paying.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ ~s|href="/checkout"|
    end
  end

  describe "when payments are not configured" do
    test "the link falls back to the form rather than dead-ending", %{conn: conn} do
      # Stripe has no secret key in test, so this is the failure path. The one
      # thing it must not do on the page that takes the money is show an error.
      conn = get(conn, ~p"/checkout/seat")

      assert redirected_to(conn) == "/checkout?plan=seat"
    end

    test "whatever the parameters say", %{conn: conn} do
      conn = get(conn, ~p"/checkout/seat?interval=year&seats=3&email=jane@acme.com")

      assert redirected_to(conn) == "/checkout?plan=seat"
    end
  end
end
