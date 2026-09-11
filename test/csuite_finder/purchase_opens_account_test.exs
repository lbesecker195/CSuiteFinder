defmodule CsuiteFinder.PurchaseOpensAccountTest do
  @moduledoc """
  Paying first, registering second.

  Stripe Checkout collects an email itself, so someone can click a price and pay
  without ever filling in a form here. The account is built afterwards from the
  address they gave Stripe — which is also the address their receipt went to, so
  it is the one they will try to sign in with.
  """

  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Accounts, Billing, Repo}
  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.{Payment, Pricing, Stripe}

  defp session(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "cs_test_#{System.unique_integer([:positive])}",
        "mode" => "payment",
        "amount_total" => 2999,
        "metadata" => %{"kind" => "seat_trial"},
        "customer_details" => %{"email" => "buyer#{System.unique_integer([:positive])}@acme.com"}
      },
      attrs
    )
  end

  describe "a purchase from someone with no account" do
    test "opens one from the address they gave the processor" do
      s = session()
      email = s["customer_details"]["email"]

      refute Accounts.get_account_by_email(email)

      {:ok, payment} = Stripe.record_payment(s)
      account = Repo.get!(Account, payment.account_id)

      assert account.email == email
      assert account.audience == "sales"
      # No password: they have not been asked for one, and inventing one would
      # be a credential nobody can use.
      assert is_nil(account.password_hash)
    end

    test "credits that account once the payment is recorded" do
      s = session()
      {:ok, payment} = Stripe.record_payment(s)
      {:ok, _} = Stripe.credit_payment(payment)

      account = Repo.get!(Account, payment.account_id)
      assert Billing.live_grant_micro(account) == Pricing.trial_micro()
      assert account.trial_granted_at
    end

    test "does not open a second account when the same person pays again" do
      first = session()
      email = first["customer_details"]["email"]
      {:ok, one} = Stripe.record_payment(first)

      {:ok, two} = Stripe.record_payment(session(%{"customer_details" => %{"email" => email}}))

      assert one.account_id == two.account_id
      assert Repo.aggregate(from(a in Account, where: a.email == ^email), :count, :id) == 1
    end
  end

  describe "a purchase that already knows its account" do
    test "uses it rather than the address on the receipt" do
      {:ok, existing} = Accounts.create_account(%{email: "known@acme.com"})

      {:ok, payment} =
        Stripe.record_payment(
          session(%{
            "metadata" => %{"account_id" => to_string(existing.id), "kind" => "topup"},
            "customer_details" => %{"email" => "someone-elses@acme.com"}
          })
        )

      assert payment.account_id == existing.id
    end
  end

  describe "what must not happen" do
    test "a replayed webhook does not credit twice" do
      s = session()
      {:ok, payment} = Stripe.record_payment(s)
      {:ok, credited} = Stripe.credit_payment(payment)

      # Stripe retries until it gets a 2xx. The second delivery is the same
      # session id, and it must buy nothing.
      {:ok, again} = Stripe.record_payment(s)
      {:ok, _} = Stripe.credit_payment(again)

      account = Repo.get!(Account, payment.account_id)
      assert Billing.live_grant_micro(account) == Pricing.trial_micro()
      assert again.id == credited.id
      assert Repo.aggregate(Payment, :count, :id) == 1
    end

    test "a session with no account and no address is refused" do
      # Crediting a guess is worse than crediting nobody: the money is
      # reconcilable, somebody else's balance is not.
      assert Stripe.record_payment(%{"id" => "cs_test_orphan", "amount_total" => 2999}) ==
               {:error, :no_account}
    end
  end
end
