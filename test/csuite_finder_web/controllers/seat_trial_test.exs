defmodule CsuiteFinderWeb.SeatTrialTest do
  @moduledoc """
  The seat side has no free tier: a trial of it is bought, once.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.{Payment, Pricing}
  alias CsuiteFinder.{Accounts, Billing, Repo}

  defp account(audience) do
    {:ok, %{account: account, api_key: key}} =
      Accounts.register(%{
        email: "trial#{System.unique_integer([:positive])}@test.com",
        audience: audience
      })

    {account, key}
  end

  describe "registering" do
    test "nobody gets free credit, on either side" do
      for audience <- ["developer", "sales"] do
        {account, _} = account(audience)

        assert account.granted_micro == 0
        assert account.balance_micro == 0
        assert account.trial_granted_at == nil
      end
    end

    test "an account gets nothing, and cannot spend" do
      {account, _} = account("sales")

      assert account.granted_micro == 0
      assert account.balance_micro == 0
      assert account.trial_granted_at == nil

      # The intended shape: no free tier means no lookups until they pay.
      assert {:error, :insufficient_credit, details} = Billing.ensure_funds(account, "email.find")
      assert details.reason == "no_balance"
    end
  end

  describe "the price" do
    test "is $29.99 and buys its own value in credit" do
      assert Pricing.trial_usd() == 29.99
      assert Pricing.trial_micro() == 29_990_000
    end

    test "is quoted to a seat holder in the terms, with no free trial alongside" do
      terms = Pricing.terms("sales")

      assert terms.audience == "sales"
      refute Map.has_key?(terms, :prices_usd)
    end
  end

  describe "what a captured trial does" do
    test "lands in the expiring pool, not the permanent one" do
      # It is a trial of the seat, so it behaves like the seat: a month, then
      # gone. Crediting the permanent pool would sell a different product.
      {account, _} = account("sales")

      {:ok, payment} =
        %Payment{}
        |> Payment.changeset(%{
          account_id: account.id,
          provider_ref: "ORDER-#{System.unique_integer([:positive])}",
          amount_micro: Pricing.trial_micro(),
          credit_micro: Pricing.trial_micro(),
          kind: "seat_trial"
        })
        |> Repo.insert()

      assert payment.kind == "seat_trial"

      # What capture would do, without PayPal in the way.
      {:ok, _} = Billing.grant(account, Pricing.trial_micro(), Pricing.trial_expires_at())

      account
      |> Account.changeset(%{trial_granted_at: DateTime.utc_now()})
      |> Repo.update!()

      reloaded = Repo.get!(Account, account.id)
      assert reloaded.granted_micro == Pricing.trial_micro()
      assert reloaded.balance_micro == 0
      assert reloaded.granted_expires_at
    end
  end

  describe "one per account" do
    test "a second trial is refused rather than sold" do
      {account, _} = account("developer")
      assert account.trial_granted_at == nil

      # What a captured trial stamps.
      {:ok, account} =
        account
        |> Account.changeset(%{trial_granted_at: DateTime.utc_now()})
        |> Repo.update()

      assert {:error, :trial_already_taken} =
               CsuiteFinder.Billing.PayPal.create_trial_order(account)
    end

    test "the balance says whether it is still available", %{conn: conn} do
      {_account, key} = account("sales")

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> get(~p"/csuitefinder/billing/balance")
        |> json_response(200)

      assert body["trial_taken"] == false
      assert body["balance_usd"] == 0
    end
  end

  describe "saying that it expires" do
    test "the sales terms quote the paid trial and its month, not a free one" do
      terms = Pricing.terms("sales")

      assert terms.trial_usd == 29.99
      assert terms.trial_months == 1
      assert terms.trial_credit_expires == true
      refute Map.has_key?(terms, :free_trial_usd)

      rules = Enum.join(terms.billing_rules, " ")
      assert rules =~ "expires after 1 month"
    end

    test "/teams says the month rather than alluding to it", %{conn: conn} do
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ "The credit expires after 1 month"
    end

    test "the home page says it on the way in", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "good for\n  1 month" or html =~ "good for 1 month"
      assert html =~ "you have\n    1 month to spend it" or html =~ "1 month to spend it"
    end

    test "and the card at the foot sells the trial, not the seat", %{conn: conn} do
      # A $999 seat is the right price to quote someone who has decided and the
      # wrong one to put in front of someone who has not.
      html = conn |> get(~p"/") |> html_response(200)
      [_, foot] = String.split(html, ~s|id="pricing"|, parts: 2)
      [card, _] = String.split(foot, "cta-note", parts: 2)

      assert card =~ "$29.99"
      # The button now goes to sales rather than to a checkout, but what it is
      # selling at this point in the page has not changed.
      assert card =~ CsuiteFinderWeb.Layout.sales_href()
      refute card =~ "$999"

      # The seat is still named, once the trial has been offered.
      assert foot =~ "$999 a month per person"
    end

    test "the signup card promises no credit to anyone", %{conn: conn} do
      # Telling someone they get free credit is a promise we no longer keep, and
      # they would find out at their first lookup.
      html = conn |> get(~p"/account") |> html_response(200)

      assert html =~ "$29.99 trial"
      assert html =~ "Credit you buy afterwards does not expire"

      # The page used to rule the free tier out in words. It no longer mentions
      # one in either direction, so what is asserted is that nothing on the page
      # offers anything free — a denial was never the point, the absence was.
      refute html =~ "of free credit"
      refute html =~ "free tier"
      refute html =~ "free account"
      refute html =~ "free trial"
    end

    test "and the account page says it at the moment of payment", %{conn: conn} do
      # A trial buyer who finds out at expiry found out too late.
      html = conn |> get(~p"/account") |> html_response(200)

      assert html =~ "It expires in"
      assert html =~ "spend it before then"
      assert html =~ "for one month"
    end
  end

  describe "the pages" do
    test "/teams sells the trial rather than giving one away", %{conn: conn} do
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ "29.99"
      refute html =~ "no card"
      refute html =~ "Try it free"
    end

    test "the account page offers it, and says it is once", %{conn: conn} do
      html = conn |> get(~p"/account") |> html_response(200)

      assert html =~ "Start the trial — $29.99"
      assert html =~ "One per account"
      refute html =~ "free tier"
    end
  end
end
