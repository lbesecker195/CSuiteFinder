defmodule CsuiteFinderWeb.SeatCheckoutTest do
  @moduledoc """
  The $999 CTA, which is one click from a marketing page to whatever takes the
  money at the time.

  Card checkout is currently switched off and every buy control is a mailto to
  sales, so what these assert is the shape that has to hold either way: a CTA
  wherever a price is quoted, and never a half-migrated page where one card
  still points at a dead processor link and the next does not.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinderWeb.Layout

  describe "the seat CTA" do
    test "goes to sales while card checkout is off", %{conn: conn} do
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ Layout.sales_href()

      # The routes behind the old buttons still exist and still work; nothing
      # should be pointing a customer at them while payments are down.
      refute html =~ ~s|href="/checkout/seat"|
      refute html =~ ~s|href="/checkout"|
    end

    test "and there is one of those buttons everywhere a price is quoted",
         %{conn: conn} do
      html = conn |> get(~p"/teams") |> html_response(200)

      count =
        Layout.sales_href()
        |> Regex.escape()
        |> Regex.compile!()
        |> Regex.scan(html)
        |> length()

      assert count >= 3,
             "only #{count} seat CTAs; the hero, the rolodex and the pricing " <>
               "card should each have one"
    end

    test "the address is not pasted into the templates by hand", %{conn: conn} do
      # Five pages carry this link. If it is typed into each of them, the day it
      # changes is the day four of them go stale and one of them is a typo that
      # silently sends nobody anywhere.
      for path <- ["/", "/teams", "/developers", "/start", "/checkout"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ Layout.sales_href(), "#{path} has no sales CTA"
      end
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
