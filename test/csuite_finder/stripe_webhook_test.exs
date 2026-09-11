defmodule CsuiteFinder.StripeWebhookTest do
  @moduledoc """
  The signature check on the webhook endpoint.

  This is the only thing standing between the open internet and "grant me a
  seat". Everything else about Stripe can be retried or reconciled; a forged
  event that passes here hands out product for free.
  """

  use ExUnit.Case, async: true

  alias CsuiteFinder.Billing.Stripe

  @secret "whsec_test_secret"

  defp sign(body, timestamp \\ System.system_time(:second), secret \\ @secret) do
    mac =
      :hmac
      |> :crypto.mac(:sha256, secret, "#{timestamp}.#{body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{mac}"
  end

  describe "a genuine event" do
    test "is accepted" do
      body = ~s({"type":"checkout.session.completed"})
      assert Stripe.verify_webhook(body, sign(body)) == :ok
    end

    test "is accepted when Stripe sends more than one signature" do
      # Stripe signs with both secrets while one is being rolled, and rejecting
      # a payload because the *first* signature is the old one would drop real
      # events for the entire rollover window.
      body = ~s({"type":"invoice.paid"})
      t = System.system_time(:second)
      "t=" <> rest = sign(body, t)
      [_, good] = String.split(rest, ",v1=")

      assert Stripe.verify_webhook(body, "t=#{t},v1=deadbeef,v1=#{good}") == :ok
    end
  end

  describe "a forged or stale event" do
    test "is rejected when the body has been changed after signing" do
      body = ~s({"amount_total":2999})
      header = sign(body)

      tampered = ~s({"amount_total":999999})
      assert Stripe.verify_webhook(tampered, header) == {:error, :invalid_signature}
    end

    test "is rejected when signed with the wrong secret" do
      body = ~s({"type":"invoice.paid"})
      header = sign(body, System.system_time(:second), "whsec_not_ours")

      assert Stripe.verify_webhook(body, header) == {:error, :invalid_signature}
    end

    test "is rejected when it is old, even though the hash is right" do
      # Without this a captured request is replayable forever.
      body = ~s({"type":"invoice.paid"})
      old = System.system_time(:second) - 3600

      assert Stripe.verify_webhook(body, sign(body, old)) ==
               {:error, :timestamp_out_of_tolerance}
    end

    test "is rejected when the header is missing or malformed" do
      body = "{}"

      assert Stripe.verify_webhook(body, nil) == {:error, :missing_signature}
      assert Stripe.verify_webhook(body, "nonsense") == {:error, :malformed_signature}
      assert Stripe.verify_webhook(body, "t=123") == {:error, :malformed_signature}
    end
  end

  describe "finding the account a payment belongs to" do
    test "from metadata" do
      assert Stripe.account_id_from(%{"metadata" => %{"account_id" => "42"}}) == {:ok, 42}
    end

    test "or from the client reference when metadata was dropped" do
      assert Stripe.account_id_from(%{"client_reference_id" => "account_7"}) == {:ok, 7}
    end

    test "and refuses to guess when neither is there" do
      # Crediting the wrong account is worse than not crediting at all: the
      # money is reconcilable, somebody else's balance is not.
      assert Stripe.account_id_from(%{"id" => "cs_test_1"}) == {:error, :no_account}
    end
  end
end
