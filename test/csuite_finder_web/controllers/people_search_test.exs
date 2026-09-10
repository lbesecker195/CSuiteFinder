defmodule CsuiteFinderWeb.PeopleSearchTest do
  @moduledoc """
  `/people/search` — who holds this job, anywhere.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.{Fixtures, PeopleSearch, Repo, TregStub}

  defp signed_in(conn, opts \\ []) do
    {account, key} = Fixtures.account_with_key(Keyword.put_new(opts, :usd, 10.0))
    {account, put_req_header(conn, "authorization", "Bearer " <> key)}
  end

  defp stub(people, cost \\ 0) do
    TregStub.stub(fn "treg.people.search", _ -> {200, %{"people" => people}, cost} end)
  end

  @vps [
    %{
      "full_name" => "Jane Doe",
      "title" => "VP Engineering",
      "company" => "Stripe",
      "company_domain" => "stripe.com",
      "email" => "jane@stripe.com"
    },
    %{
      "first_name" => "Sam",
      "last_name" => "Roe",
      "position" => "VP of Engineering",
      "company_name" => "Wise",
      "domain" => "https://wise.com/careers"
    }
  ]

  describe "searching by role" do
    test "returns people across companies", %{conn: conn} do
      stub(@vps)
      {_account, conn} = signed_in(conn)

      body =
        conn
        |> get(~p"/csuitefinder/people/search?title=VP%20Engineering")
        |> json_response(200)

      assert body["count"] == 2
      assert [first, second] = body["people"]
      assert first["full_name"] == "Jane Doe"
      assert first["company_domain"] == "stripe.com"
      # A name assembled from parts, and a domain dug out of a careers URL.
      assert second["full_name"] == "Sam Roe"
      assert second["company_domain"] == "wise.com"
    end

    test "a search with no filters is refused", %{conn: conn} do
      {_account, conn} = signed_in(conn)
      assert conn |> get(~p"/csuitefinder/people/search") |> json_response(400)
    end

    test "a row with no name at all is dropped" do
      stub([%{"title" => "VP Engineering"}, %{"full_name" => "Jane Doe"}])
      {:ok, people, _} = PeopleSearch.search(%{title: "VP Engineering"})
      assert Enum.map(people, & &1["full_name"]) == ["Jane Doe"]
    end

    test "the same person from two providers is one row" do
      stub([
        %{"full_name" => "Jane Doe", "email" => "jane@stripe.com"},
        %{"full_name" => "Jane Doe", "email" => "jane@stripe.com", "title" => "VP"}
      ])

      {:ok, people, _} = PeopleSearch.search(%{title: "VP"})
      assert length(people) == 1
    end

    test "two people who share a name and have no email both survive" do
      # This is where a cleverer key would silently delete a real person.
      stub([
        %{"full_name" => "Jane Doe", "company" => "Stripe"},
        %{"full_name" => "Jane Doe", "company" => "Wise"}
      ])

      {:ok, people, _} = PeopleSearch.search(%{title: "VP"})
      assert length(people) == 2
    end
  end

  describe "addresses in the rows" do
    test "every row says the address is unverified", %{conn: conn} do
      # A directory listing is not a checked mailbox. A field that were
      # sometimes true would be read as "sometimes safe to send".
      stub(@vps)
      {_account, conn} = signed_in(conn)

      body = conn |> get(~p"/csuitefinder/people/search?title=VP") |> json_response(200)

      for person <- body["people"] do
        assert person["verified"] == false
      end
    end

    test "and the response names the endpoint that checks them", %{conn: conn} do
      stub(@vps)
      {_account, conn} = signed_in(conn)

      body = conn |> get(~p"/csuitefinder/people/search?title=VP") |> json_response(200)

      assert body["advice"] =~ "deliverable"
      assert body["next"]["verify"] =~ "/email/deliverable"
    end
  end

  describe "cost" do
    test "the free providers are reachable, because every search carries a description" do
      # The cheapest providers match on a free-text query. A title-only request
      # would sail past them into a paid one.
      TregStub.stub(fn "treg.people.search", body ->
        assert body["q"] =~ "VP Engineering", "no description was sent"
        {200, %{"people" => []}, 0}
      end)

      {:ok, [], lookup} = PeopleSearch.search(%{title: "VP Engineering"})
      assert lookup.spent_micro == 0
    end

    test "bills per person returned", %{conn: conn} do
      stub(@vps)
      {account, conn} = signed_in(conn, usd: 1.0)

      conn |> get(~p"/csuitefinder/people/search?title=VP") |> json_response(200)

      spent = Pricing.micro(1.0) - Repo.reload(account).balance_micro
      assert spent == Pricing.charge_for("people.search") * 2
    end

    test "a search that matches nobody is free", %{conn: conn} do
      stub([])
      {account, conn} = signed_in(conn, usd: 1.0)

      conn |> get(~p"/csuitefinder/people/search?title=Nobody") |> json_response(200)
      assert Repo.reload(account).balance_micro == Pricing.micro(1.0)
    end

    test "you cannot ask for more rows than you can pay for", %{conn: conn} do
      stub(for n <- 1..30, do: %{"full_name" => "Person #{n}", "email" => "p#{n}@x.example"})
      {_account, conn} = signed_in(conn, usd: 0.005)

      body = conn |> get(~p"/csuitefinder/people/search?title=VP&limit=30") |> json_response(200)
      assert body["count"] == 2
    end
  end

  describe "caching" do
    test "the same question twice is one purchase" do
      stub(@vps)
      {:ok, _, first} = PeopleSearch.search(%{title: "VP Engineering"})
      refute first.cached

      stub([])
      {:ok, people, second} = PeopleSearch.search(%{title: "  vp engineering "})

      assert second.cached
      assert length(people) == 2
    end

    test "a different question is a different purchase" do
      stub(@vps)
      {:ok, _, _} = PeopleSearch.search(%{title: "VP Engineering"})
      {:ok, _, second} = PeopleSearch.search(%{title: "CFO"})
      refute second.cached
    end
  end

  describe "the supplier stays ours" do
    test "no provider name reaches the response", %{conn: conn} do
      stub(@vps)
      {_account, conn} = signed_in(conn)

      encoded =
        conn
        |> get(~p"/csuitefinder/people/search?title=VP")
        |> json_response(200)
        |> Jason.encode!()
        |> String.downcase()

      for term <- ~w(treg apollo leadsforge quickenrich lusha provider served_by) do
        refute String.contains?(encoded, term), "response mentioned #{term}"
      end
    end
  end
end
