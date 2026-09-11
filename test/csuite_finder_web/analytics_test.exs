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

  describe "engagement, so the reported time means something" do
    test "rides along with the tag" do
      Application.put_env(:csuite_finder, :ga_measurement_id, "G-TEST123")

      assert Analytics.tag() =~ "scroll_depth"
      assert Analytics.tag() =~ "time_on_page"
    end

    test "counts time only while the tab is in front" do
      # GA4 counts engagement the same way, and a tab left open overnight is
      # not two hours of reading.
      js = Analytics.engagement_tracking()

      assert js =~ ~s|document.visibilityState !== "visible"|
    end

    test "treats a page shorter than the window as fully read" do
      # Otherwise every short page reports 0% depth and drags the average down
      # for a reason that has nothing to do with the reader.
      js = Analytics.engagement_tracking()

      assert js =~ "scrollable <= 0 ? 100"
    end

    test "fires each milestone once rather than on a heartbeat" do
      # A ping every second would measure the same thing and triple the event
      # volume, which costs quota and buys nothing.
      js = Analytics.engagement_tracking()

      assert js =~ "seenDepth[mark]"
      assert js =~ "reached += 1"
    end

    test "sends the count every second, on the second" do
      js = Analytics.engagement_tracking()

      assert js =~ "dwell_time"
      assert js =~ "setInterval(tick, 1000)"
      # Aligned to the wall clock, so two visitors' events land on the same
      # boundaries and compare without allowing for when each began.
      assert js =~ "1000 - (Date.now() % 1000)"
    end

    test "stops at 400 so the session has events left for a conversion" do
      # GA4 drops everything after the 500th event in a session. The ones worth
      # keeping arrive late — a click, a purchase — so the counter yields the
      # last hundred rather than spending them saying "still here" again.
      js = Analytics.engagement_tracking()

      assert js =~ "var LIMIT = 400;"
      assert js =~ "clearInterval(timer)"
    end

    test "and marks the stop, so a long visit is not mistaken for a short one" do
      js = Analytics.engagement_tracking()

      assert js =~ "dwell_capped"
    end

    test "does not report on the way out" do
      # Asked for explicitly: the count goes out as it accrues, not at the end.
      js = Analytics.engagement_tracking()

      refute js =~ "pagehide"
      refute js =~ "beacon"
    end

    test "is silent when analytics are switched off" do
      Application.put_env(:csuite_finder, :ga_measurement_id, nil)
      assert Analytics.tag() == ""
    end
  end
end
