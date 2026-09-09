defmodule CsuiteFinderWeb.AdminTest do
  # Not async: these manipulate the application-wide admin token.
  use CsuiteFinderWeb.ConnCase, async: false

  @token "test-admin-token"

  setup do
    previous = Application.get_env(:csuite_finder, :admin_token)
    Application.put_env(:csuite_finder, :admin_token, @token)

    on_exit(fn ->
      if previous do
        Application.put_env(:csuite_finder, :admin_token, previous)
      else
        Application.delete_env(:csuite_finder, :admin_token)
      end
    end)

    :ok
  end

  describe "authentication" do
    test "refuses an anonymous request", %{conn: conn} do
      assert conn |> get(~p"/admin") |> response(401)
    end

    test "refuses a wrong token", %{conn: conn} do
      assert conn |> get(~p"/admin?token=wrong") |> response(401)
    end

    test "accepts the token in a query parameter", %{conn: conn} do
      assert conn |> get(~p"/admin?token=#{@token}") |> html_response(200)
    end

    test "accepts a bearer header", %{conn: conn} do
      assert conn
             |> put_req_header("authorization", "Bearer " <> @token)
             |> get(~p"/admin")
             |> html_response(200)
    end

    test "accepts an X-Admin-Token header", %{conn: conn} do
      assert conn
             |> put_req_header("x-admin-token", @token)
             |> get(~p"/admin")
             |> html_response(200)
    end

    test "is closed, not open, when no token is configured", %{conn: conn} do
      # The failure mode of a missing environment variable must be "nobody sees
      # the metrics", never "everybody does".
      Application.delete_env(:csuite_finder, :admin_token)
      System.delete_env("ADMIN_TOKEN")

      assert conn |> get(~p"/admin") |> response(503)
    end

    test "guards the JSON endpoint too", %{conn: conn} do
      assert conn |> get(~p"/admin/metrics.json") |> response(401)
    end
  end

  describe "GET /admin" do
    test "renders without traffic rather than dividing by zero", %{conn: conn} do
      html = conn |> get(~p"/admin?token=#{@token}") |> html_response(200)

      assert html =~ "CSuiteFinder"
      assert html =~ "No requests in this window yet."
    end

    test "keeps the token on the window links so they stay clickable", %{conn: conn} do
      html = conn |> get(~p"/admin?token=#{@token}") |> html_response(200)

      assert html =~ "days=7&amp;token=#{@token}"
      assert html =~ "days=90&amp;token=#{@token}"
    end

    test "escapes values that reach the markup", %{conn: conn} do
      # The template is plain EEx and does not auto-escape. Only a correct token
      # ever renders the page, so this is not reachable by an attacker — but the
      # helper must not be a trap for whatever is added to this page next.
      alias CsuiteFinderWeb.AdminController

      assert AdminController.esc(~s(<script>"x"&'y')) ==
               "&lt;script&gt;&quot;x&quot;&amp;&#39;y&#39;"

      html = conn |> get(~p"/admin?token=#{@token}") |> html_response(200)
      refute html =~ "days=7&token="
      assert html =~ "days=7&amp;token="
    end

    test "defaults to 30 days and ignores an unsupported window", %{conn: conn} do
      html = conn |> get(~p"/admin?token=#{@token}&days=999") |> html_response(200)
      assert html =~ "Last 30 days"
    end

    test "shows traffic once there is some", %{conn: conn} do
      {account, key} = CsuiteFinder.Fixtures.account_with_key(tokens: 400)

      CsuiteFinder.TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}, 1_900}
      end)

      build_conn()
      |> put_req_header("authorization", "Bearer " <> key)
      |> get(~p"/csuitefinder/email/find?full_name=Jane%20Doe&domain=acme.com")
      |> json_response(200)

      html = conn |> get(~p"/admin?token=#{@token}") |> html_response(200)

      assert html =~ "email.find"
      refute html =~ "No requests in this window yet."
      assert CsuiteFinder.Repo.reload(account).token_balance == 399
    end
  end

  describe "GET /admin/metrics.json" do
    test "serves the same numbers as the page", %{conn: conn} do
      body =
        conn
        |> put_req_header("x-admin-token", @token)
        |> get(~p"/admin/metrics.json")
        |> json_response(200)

      assert body["days"] == 30
      assert body["headline"]["requests"] == 0
      assert length(body["daily"]) == 30
      assert body["find_economics"]["price_micro"] == 2_500
    end

    test "honours the window parameter", %{conn: conn} do
      body =
        conn
        |> put_req_header("x-admin-token", @token)
        |> get(~p"/admin/metrics.json?days=7")
        |> json_response(200)

      assert body["days"] == 7
      assert length(body["daily"]) == 7
    end
  end
end
