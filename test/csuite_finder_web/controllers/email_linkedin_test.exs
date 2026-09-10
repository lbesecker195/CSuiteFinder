defmodule CsuiteFinderWeb.EmailLinkedinTest do
  @moduledoc """
  `/email/linkedin` — the same answer from the other input people hold.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.Cache.EmailPattern
  alias CsuiteFinder.{Fixtures, Repo, TregStub}

  defp signed_in(conn, opts \\ []) do
    {account, key} = Fixtures.account_with_key(Keyword.put_new(opts, :usd, 10.0))
    {account, put_req_header(conn, "authorization", "Bearer " <> key)}
  end

  defp stub_find(email, name \\ "Jensen Huang") do
    TregStub.stub(fn
      "treg.people.email.verify", _ ->
        {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}

      "treg.people.email.find", _ ->
        {200, %{"output" => %{"email" => email, "full_name" => name}}, 8_900}
    end)
  end

  describe "resolving a profile" do
    test "returns the address behind a profile URL", %{conn: conn} do
      stub_find("jhuang@nvidia.com")
      {_account, conn} = signed_in(conn)

      body =
        conn
        |> get(
          ~p"/csuitefinder/email/linkedin?linkedin_url=https://www.linkedin.com/in/jensenhuang"
        )
        |> json_response(200)

      assert body["email"] == "jhuang@nvidia.com"
      assert body["found"] == true
      assert body["domain"] == "nvidia.com"
    end

    test "a URL that is not a profile is refused before anything is spent", %{conn: conn} do
      {account, conn} = signed_in(conn, usd: 1.0)

      conn
      |> get(~p"/csuitefinder/email/linkedin?linkedin_url=https://example.com/jane")
      |> json_response(400)

      assert Repo.reload(account).balance_micro == Pricing.micro(1.0)
    end

    test "the same profile written three ways is one purchase" do
      stub_find("jhuang@nvidia.com")

      {:ok, first} =
        CsuiteFinder.Finder.find_by_linkedin("https://www.linkedin.com/in/jensenhuang")

      refute first.cached

      TregStub.stub(fn "treg.people.email.find", _ -> {200, %{"output" => nil}, 8_900} end)

      for variant <- [
            "linkedin.com/in/jensenhuang",
            "http://uk.linkedin.com/in/jensenhuang/",
            "https://www.linkedin.com/in/jensenhuang?utm_source=share"
          ] do
        {:ok, again} = CsuiteFinder.Finder.find_by_linkedin(variant)
        assert again.cached, "#{variant} was bought again"
        assert again.email == "jhuang@nvidia.com"
      end
    end
  end

  describe "what the answer teaches us" do
    test "the company's format is banked, so the next person there is free" do
      # The address is worth less than the format it reveals: one profile
      # lookup makes everyone else at that company resolvable on the cheap path.
      stub_find("jensen.huang@nvidia.com", "Jensen Huang")
      {:ok, _} = CsuiteFinder.Finder.find_by_linkedin("https://www.linkedin.com/in/jensenhuang")

      assert %EmailPattern{pattern: "{first}.{last}"} =
               Repo.get_by(EmailPattern, domain: "nvidia.com")
    end
  end

  describe "pricing" do
    test "costs more than a name-and-domain find, and says so in the price list" do
      # A profile carries no domain, so the format shortcut cannot apply and
      # every one of these is a provider call.
      assert Pricing.charge_for("email.linkedin") > Pricing.charge_for("email.find")
      assert Pricing.list_usd()["email.linkedin"] == 0.015
    end

    test "bills the profile price, not the find price", %{conn: conn} do
      stub_find("jhuang@nvidia.com")
      {account, conn} = signed_in(conn, usd: 1.0)

      conn
      |> get(
        ~p"/csuitefinder/email/linkedin?linkedin_url=https://www.linkedin.com/in/jensenhuang"
      )
      |> json_response(200)

      spent = Pricing.micro(1.0) - Repo.reload(account).balance_micro
      assert spent == Pricing.charge_for("email.linkedin")
    end

    test "a profile with no address behind it is free", %{conn: conn} do
      TregStub.stub(fn "treg.people.email.find", _ -> {200, %{"output" => nil}, 8_900} end)
      {account, conn} = signed_in(conn, usd: 1.0)

      conn
      |> get(~p"/csuitefinder/email/linkedin?linkedin_url=https://www.linkedin.com/in/nobody")
      |> json_response(200)

      assert Repo.reload(account).balance_micro == Pricing.micro(1.0)
    end
  end
end
