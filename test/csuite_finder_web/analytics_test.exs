defmodule CsuiteFinderWeb.AnalyticsTest do
  @moduledoc """
  The tag, and the click tracking that rides with it.

  The rule worth a test is the one about query strings: a campaign link arrives
  as `?email=someone@company.com`, so anything that reports a URL has to report
  a path.
  """

  use CsuiteFinderWeb.ConnCase, async: false

  alias CsuiteFinderWeb.Analytics

  setup do
    original = Application.get_env(:csuite_finder, :ga_measurement_id)
    on_exit(fn -> Application.put_env(:csuite_finder, :ga_measurement_id, original) end)
    :ok
  end

  describe "click tracking" do
    test "rides along with the tag, so a new button needs no wiring" do
      Application.put_env(:csuite_finder, :ga_measurement_id, "G-TEST123")

      tag = Analytics.tag()

      assert tag =~ "G-TEST123"
      assert tag =~ "cta_click"
      # Delegated from the document, which is what makes it cover controls that
      # do not exist yet.
      assert tag =~ ~s|document.addEventListener("click"|
      assert tag =~ ~s|closest("a, button")|
    end

    test "never reports a query string, because campaign links carry an address" do
      js = Analytics.click_tracking()

      # Paths, both for the href and for the page the click happened on.
      assert js =~ "new URL(url, window.location.origin).pathname"
      assert js =~ "window.location.pathname"

      # An outbound href is kept whole apart from its query, which is the one
      # place a full URL is worth having.
      assert js =~ ~s|href.split("?")[0]|

      # Nothing that would carry a typed value into an event. The rule is about
      # *reading* what somebody entered — the tracker writes an `event.value`
      # for the price of the offer, which is a number from the markup, not from
      # a field. So this asserts the tracker never goes near an input at all.
      refute js =~ "input"
      refute js =~ "FormData"
      refute js =~ "window.location.search"
    end

    test "does nothing at all when analytics are switched off" do
      Application.put_env(:csuite_finder, :ga_measurement_id, nil)

      assert Analytics.tag() == ""
    end

    test "and is inert on a page where gtag never loaded" do
      # A blocked or failed tag script must not turn every click into an error.
      assert Analytics.click_tracking() =~ ~s|typeof window.gtag !== "function"|
    end
  end

  describe "which offer was clicked" do
    test "the two prices are told apart by name, not by URL" do
      js = Analytics.click_tracking()

      # A path changes when a processor or a route changes, and both have
      # changed twice here. The markup says what is being bought.
      assert js =~ ~s|closest("[data-cta]")|
      assert js =~ "event.cta ="
    end

    test "and the price rides along as money GA4 understands" do
      js = Analytics.click_tracking()

      assert js =~ "data-cta-usd"
      assert js =~ ~s|event.currency = "USD"|
    end
  end

  describe "the CTAs themselves" do
    setup %{conn: conn}, do: {:ok, html: conn |> get(~p"/teams") |> html_response(200)}

    test "a seat button says it is the seat, at the seat price", %{html: html} do
      assert html =~ ~s|data-cta="seat_monthly"|
      assert html =~ ~s|data-cta-usd="999"|
    end

    test "a trial button says it is the trial, at the trial price", %{html: html} do
      assert html =~ ~s|data-cta="trial"|
      assert html =~ ~s|data-cta-usd="29.99"|
    end

    test "and every purchase button on the page carries one", %{html: html} do
      # An unmarked button reports as an anonymous cta_click, which is the
      # failure this is guarding: the numbers look complete and the offer that
      # matters is missing from them.
      buttons = Regex.scan(~r|<a [^>]*href="(/checkout[^"]*)"|, html, capture: :all_but_first)
      marked = Regex.scan(~r|data-cta="|, html)

      assert length(marked) >= length(buttons),
             "#{length(buttons)} checkout links but only #{length(marked)} marked"
    end
  end
end
