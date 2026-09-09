defmodule CsuiteFinderWeb.RegistrationController do
  @moduledoc """
  Self-serve signup. One call, and the caller has a working key and enough
  trial tokens to evaluate the API without talking to anyone.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Accounts
  alias CsuiteFinder.Billing.Pricing

  action_fallback CsuiteFinderWeb.FallbackController

  @doc "POST /csuitefinder/register"
  def create(conn, params) do
    case Accounts.register(%{
           email: params["email"],
           name: params["name"],
           audience: params["audience"]
         }) do
      {:ok, %{account: account, api_key: key, credit_granted_micro: granted}} ->
        conn
        |> put_status(:created)
        |> json(%{
          account_id: account.id,
          email: account.email,
          audience: account.audience,
          api_key: key,
          # Said plainly, because there is no second chance to read it.
          api_key_notice:
            "Store this key now — it is shown once and cannot be recovered. " <>
              "Send it as `Authorization: Bearer <key>`.",
          credit_notice:
            "Trial credit expires #{Pricing.trial_months()} month after sign-up. Credit you buy does not expire.",
          credit_granted_usd: Pricing.usd(granted),
          credit_expires_at: account.granted_expires_at,
          balance_usd: Pricing.usd(CsuiteFinder.Billing.available_micro(account)),
          terms: Pricing.terms(),
          next_steps: [
            "GET /csuitefinder/email/find?full_name=Jane%20Doe&domain=acme.com",
            "GET /csuitefinder/billing/balance",
            "POST /csuitefinder/billing/topup {\"amount_usd\": 1000}"
          ]
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "registration_failed", details: errors(changeset)})
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
