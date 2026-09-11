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

      # Nothing that would carry a typed value into an event.
      refute js =~ ".value"
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
end
