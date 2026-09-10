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
    test "a developer still gets the free dollar" do
      {account, _} = account("developer")

      assert account.granted_micro == Pricing.trial_micro()
      assert account.trial_granted_at
    end

    test "a seat account gets nothing, and cannot spend" do
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
      assert Pricing.seat_trial_usd() == 29.99
      assert Pricing.seat_trial_micro() == 29_990_000
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
          paypal_order_id: "ORDER-#{System.unique_integer([:positive])}",
          amount_micro: Pricing.seat_trial_micro(),
          credit_micro: Pricing.seat_trial_micro(),
          kind: "seat_trial"
        })
        |> Repo.insert()

      assert payment.kind == "seat_trial"

      # What capture would do, without PayPal in the way.
      {:ok, _} = Billing.grant(account, Pricing.seat_trial_micro(), Pricing.trial_expires_at())

      account
      |> Account.changeset(%{trial_granted_at: DateTime.utc_now()})
      |> Repo.update!()

      reloaded = Repo.get!(Account, account.id)
      assert reloaded.granted_micro == Pricing.seat_trial_micro()
      assert reloaded.balance_micro == 0
      assert reloaded.granted_expires_at
    end
  end

  describe "one per account" do
    test "a second trial is refused rather than sold" do
      {account, _} = account("developer")
      # The free grant already stamped it, which is the same gate.
      assert account.trial_granted_at

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
      assert html =~ "no free tier on this side"
    end
  end
end
