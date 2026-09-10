defmodule CsuiteFinderWeb.AudienceAccessTest do
  @moduledoc """
  A key is a key.

  Which half of the business an account was opened under decides what the
  website shows it and how the rate card is quoted. It decides nothing about
  what the API will do. This file exists because that is easy to "helpfully"
  restrict later, and restricting it would break every seat holder pointing an
  assistant at llms.txt — which is the whole way a seat is meant to be used.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.{Fixtures, TregStub}

  defp keyed(conn, audience) do
    {_account, key} = Fixtures.account_with_key(usd: 5.0, audience: audience)
    put_req_header(conn, "authorization", "Bearer " <> key)
  end

  describe "every lookup" do
    test "answers a sales key exactly as it answers a developer key", %{conn: conn} do
      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}, 1_900}
      end)

      answers =
        for audience <- ["sales", "developer"] do
          conn
          |> keyed(audience)
          |> get(~p"/csuitefinder/email/find?full_name=Jane%20Doe&domain=acme.com")
          |> json_response(200)
        end

      assert [%{"email" => "jane.doe@acme.com"}, %{"email" => "jane.doe@acme.com"}] = answers
    end

    test "and the discovery routes too", %{conn: conn} do
      TregStub.stub(fn "treg.companies.search", _ ->
        {200, %{"companies" => [%{"name" => "Acme", "domain" => "acme.com"}]}, 3_800}
      end)

      for audience <- ["sales", "developer"] do
        body =
          conn
          |> keyed(audience)
          |> get(~p"/csuitefinder/company/search?industry=widgets")
          |> json_response(200)

        assert body["count"] == 1
      end
    end
  end

  describe "what the audience does change" do
    test "is the rate card, and only that", %{conn: conn} do
      sales =
        conn |> keyed("sales") |> get(~p"/csuitefinder/billing/balance") |> json_response(200)

      developer =
        build_conn()
        |> keyed("developer")
        |> get(~p"/csuitefinder/billing/balance")
        |> json_response(200)

      # A seat holder is not quoted a per-answer price list; a developer is.
      refute sales["prices_usd"]
      assert developer["prices_usd"]

      # Both can spend, and both are told the same about what they hold.
      assert sales["balance_usd"] == developer["balance_usd"]
    end
  end
end
