defmodule CsuiteFinder.SquareWebhookTest do
  @moduledoc """
  Square's webhook signature, and the trap in it.

  Square signs `notification_url <> body`, not the body alone. The URL is part
  of the signed material, so the one configured in Square's dashboard has to
  match ours character for character — and when it does not, every genuine event
  is rejected with the same error a forgery would produce. That is the failure
  worth a test, because the symptom is "payments silently stop crediting".
  """

  use ExUnit.Case, async: true

  alias CsuiteFinder.Billing.Square

  @key "square_test_signature_key"
  @url "https://csuitefinder.test/csuitefinder/billing/webhook"

  defp sign(body, url \\ @url, key \\ @key) do
    :hmac |> :crypto.mac(:sha256, key, url <> body) |> Base.encode64()
  end

  describe "a genuine event" do
    test "is accepted" do
      body = ~s({"type":"payment.updated"})
      assert Square.verify_webhook(body, sign(body), @url) == :ok
    end
  end

  describe "what is rejected" do
    test "a body changed after signing" do
      body = ~s({"amount_money":{"amount":2999}})
      signature = sign(body)

      assert Square.verify_webhook(~s({"amount_money":{"amount":999999}}), signature, @url) ==
               {:error, :invalid_signature}
    end

    test "the wrong signing key" do
      body = ~s({"type":"payment.updated"})

      assert Square.verify_webhook(body, sign(body, @url, "not_our_key"), @url) ==
               {:error, :invalid_signature}
    end

    test "a notification URL that does not match the one Square was given" do
      # The whole point of this file. A trailing slash is enough, and nothing
      # about the resulting error says the URL is what is wrong.
      body = ~s({"type":"payment.updated"})
      signature = sign(body, @url <> "/")

      assert Square.verify_webhook(body, signature, @url) == {:error, :invalid_signature}
    end

    test "no signature at all" do
      assert Square.verify_webhook("{}", nil, @url) == {:error, :missing_signature}
    end
  end

  describe "finding the account and the kind" do
    test "from the note we stamped on the order" do
      assert Square.account_id_from(%{"note" => "account_42|seat_trial"}) == {:ok, 42}
    end

    test "and refusing to guess when the note is a new buyer" do
      # "account_new" is what an anonymous purchase carries. It must not parse
      # as an id — crediting the wrong account is worse than crediting none,
      # because the money is reconcilable and somebody else's balance is not.
      assert Square.account_id_from(%{"note" => "account_new|seat_trial"}) ==
               {:error, :no_account}

      assert Square.account_id_from(%{"id" => "pay_1"}) == {:error, :no_account}
    end
  end

  describe "which events actually do something" do
    # Ticking the wrong boxes in Square's dashboard is a silent failure: the
    # endpoint answers 200 and nothing is ever credited. These name the events
    # the handler acts on, so the list in the dashboard has something to match.

    test "a completed payment is the event that credits" do
      assert handles?("payment.updated")
      assert handles?("payment.created")
    end

    test "an invoice payment is how a seat renews" do
      assert handles?("invoice.payment_made")
    end

    test "a subscription change only mirrors status" do
      assert handles?("subscription.updated")
    end

    test "subscription.created alone would credit nothing" do
      # It describes a plan starting, not money moving. On its own the account
      # would have a subscription and no credit — which is the exact shape of
      # the question this answers.
      refute handles?("subscription.created")
    end
  end

  # Reads the controller rather than asserting on a list kept in the test, so a
  # handler removed from the code fails here.
  defp handles?(event) do
    File.read!("lib/csuite_finder_web/controllers/billing_controller.ex")
    |> String.contains?(~s("#{event}"))
  end
end
