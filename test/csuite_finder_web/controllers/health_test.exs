defmodule CsuiteFinderWeb.HealthTest do
  @moduledoc """
  The health check is how anyone finds out whether a deployment can take money.
  """

  use CsuiteFinderWeb.ConnCase, async: false

  alias CsuiteFinder.Billing.PayPal

  setup do
    original = Application.get_env(:csuite_finder, PayPal, [])
    on_exit(fn -> Application.put_env(:csuite_finder, PayPal, original) end)
    {:ok, original: original}
  end

  defp with_paypal(opts, original) do
    Application.put_env(:csuite_finder, PayPal, Keyword.merge(original, opts))
  end

  test "reports the two settings that otherwise fail silently", %{conn: conn, original: original} do
    with_paypal(
      [
        client_id: "id",
        client_secret: "secret",
        webhook_id: "WH-123",
        base_url: "https://api-m.paypal.com"
      ],
      original
    )

    body = conn |> get(~p"/csuitefinder/health") |> json_response(200)

    assert body["payments_configured"]
    assert body["payments_webhooks_configured"]
    assert body["payments_mode"] == "live"
  end

  test "a missing webhook id is visible, even though everything else looks fine",
       %{conn: conn, original: original} do
    # This is the failure worth catching: payments still capture from the
    # browser, so nothing looks broken, but every callback PayPal retries is
    # dropped and that credit is never applied.
    with_paypal([client_id: "id", client_secret: "secret", webhook_id: nil], original)

    body = conn |> get(~p"/csuitefinder/health") |> json_response(200)

    assert body["payments_configured"]
    refute body["payments_webhooks_configured"]
  end

  test "sandbox credentials do not masquerade as live ones",
       %{conn: conn, original: original} do
    with_paypal(
      [client_id: "id", client_secret: "secret", base_url: "https://api-m.sandbox.paypal.com"],
      original
    )

    assert conn |> get(~p"/csuitefinder/health") |> json_response(200) |> Map.get("payments_mode") ==
             "sandbox"
  end

  test "names no supplier", %{conn: conn} do
    # A health check is public, and it must not say who we buy from.
    encoded = conn |> get(~p"/csuitefinder/health") |> json_response(200) |> Jason.encode!()

    for term <- ~w(treg paypal anthropic tomba hunter) do
      refute String.contains?(String.downcase(encoded), term), "health mentioned #{term}"
    end
  end
end
