defmodule CsuiteFinder.ProspectPaginationTest do
  @moduledoc """
  Reaching past the first page of a company.

  The provider paginates and reports a total — Stripe comes back as 5,113 people
  across 512 pages — and we were sending neither a page nor reading the total.
  One call therefore looked identical whether it had returned everybody or the
  first ten of five thousand.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.{Fixtures, TregStub}

  defp people(n, from) do
    for i <- from..(from + n - 1) do
      %{
        "email" => "person#{i}@acme.com",
        "first_name" => "Person",
        "last_name" => "#{i}",
        "position" => "Engineer",
        "department" => "engineering"
      }
    end
  end

  # Named `upstream`, not `endpoint`: Phoenix's ConnCase already owns @endpoint
  # and shadowing it breaks every ~p in the file.
  @upstream "tomba.companies.emails.list"

  defp stub_pages do
    # The stub is handed body and query merged into one string-keyed map, so the
    # page arrives as "2" rather than 2 — which is also exactly how it reaches
    # the provider, and therefore what this needs to read to prove we sent it.
    TregStub.stub(fn @upstream, params ->
      page =
        case Integer.parse(to_string(Map.get(params, "page", "1"))) do
          {n, _} when n > 0 -> n
          _ -> 1
        end

      {200,
       %{"data" => %{"emails" => people(10, (page - 1) * 10 + 1)}, "meta" => %{"total" => 40}},
       8_900}
    end)
  end

  setup %{conn: conn} do
    {_account, key} = Fixtures.account_with_key(usd: 50.0)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> key)}
  end

  describe "asking for a later page" do
    test "sends the page upstream and returns different people", %{conn: conn} do
      stub_pages()

      one =
        conn
        |> get(~p"/csuitefinder/company/people?domain=acme.com&limit=10&page=1")
        |> json_response(200)

      two =
        conn
        |> get(~p"/csuitefinder/company/people?domain=acme.com&limit=10&page=2")
        |> json_response(200)

      emails = fn body -> body["people"] |> Enum.map(& &1["email"]) |> MapSet.new() end

      assert one["page"] == 1
      assert two["page"] == 2

      assert MapSet.size(MapSet.intersection(emails.(one), emails.(two))) == 0,
             "page two repeated people from page one"
    end

    test "reports the provider's total, so a caller knows there is more",
         %{conn: conn} do
      stub_pages()

      body =
        conn
        |> get(~p"/csuitefinder/company/people?domain=acme.com&limit=10&page=1")
        |> json_response(200)

      assert body["total"] == 40
      assert body["has_more"] == true
    end

    test "and says when the last page has been reached", %{conn: conn} do
      stub_pages()

      body =
        conn
        |> get(~p"/csuitefinder/company/people?domain=acme.com&limit=10&page=4")
        |> json_response(200)

      assert body["has_more"] == false
    end
  end

  describe "a page nobody specified" do
    test "is the first one", %{conn: conn} do
      stub_pages()

      body =
        conn
        |> get(~p"/csuitefinder/company/people?domain=acme.com&limit=10")
        |> json_response(200)

      assert body["page"] == 1
    end

    test "and nonsense does not become page zero or a negative offset",
         %{conn: conn} do
      stub_pages()

      for bad <- ["0", "-3", "abc", ""] do
        body =
          conn
          |> get("/csuitefinder/company/people?domain=acme.com&limit=10&page=#{bad}")
          |> json_response(200)

        assert body["page"] == 1, "page=#{bad} did not fall back to the first page"
      end
    end
  end
end
