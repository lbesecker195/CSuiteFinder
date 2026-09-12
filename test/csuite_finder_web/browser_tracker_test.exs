defmodule CsuiteFinderWeb.BrowserTrackerTest do
  @moduledoc """
  Where the browser tracker runs, and the one place it does not.

  It captures clicks and form interaction on its own, with no tagging. That is
  the point of it everywhere except the account page, which shows a plaintext
  API key once and carries the password fields for registering and signing in.
  """

  use CsuiteFinderWeb.ConnCase, async: false

  alias CsuiteFinderWeb.Analytics

  @src "https://seriouslysimpleanalytics.com/wa.js"

  setup do
    original = Application.get_env(:csuite_finder, :ssa_site_id)
    Application.put_env(:csuite_finder, :ssa_site_id, "acct_ssl8gfuynd")
    on_exit(fn -> Application.put_env(:csuite_finder, :ssa_site_id, original) end)
    :ok
  end

  describe "the marketing pages" do
    test "carry the tracker", %{conn: conn} do
      for path <- ["/", "/teams", "/developers", "/start", "/checkout"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ @src, "#{path} is missing the tracker"
        assert html =~ ~s(data-site="acct_ssl8gfuynd"), "#{path} has the wrong site id"
        assert html =~ "defer", "#{path} loads the tracker without defer"
      end
    end
  end

  describe "the account page" do
    test "does not, because it holds credentials", %{conn: conn} do
      # A key is shown there once and nowhere else, and the register and sign-in
      # fields are on it. A tracker that captures forms has no business on that
      # page — their own docs concede the server "drops password-typed values on
      # arrival", which is only worth saying about a thing that can receive them.
      html = conn |> get(~p"/account") |> html_response(200)

      refute html =~ @src
    end

    test "and neither does the admin dashboard" do
      # Operator traffic counted as a customer's makes every number wrong.
      refute Analytics.browser_tracker(false) =~ @src
    end
  end

  describe "switching it off" do
    test "a blank site id emits nothing" do
      Application.put_env(:csuite_finder, :ssa_site_id, nil)

      refute Analytics.tag(:teams) =~ @src
      assert Analytics.browser_tracker(:teams) == ""
    end
  end
end
