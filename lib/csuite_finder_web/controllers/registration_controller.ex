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
    case Accounts.register(%{email: params["email"], name: params["name"]}) do
      {:ok, %{account: account, api_key: key, tokens_granted: tokens}} ->
        conn
        |> put_status(:created)
        |> json(%{
          account_id: account.id,
          email: account.email,
          api_key: key,
          # Said plainly, because there is no second chance to read it.
          api_key_notice:
            "Store this key now — it is shown once and cannot be recovered. " <>
              "Send it as `Authorization: Bearer <key>`.",
          tokens_granted: tokens,
          tokens_granted_usd: Pricing.usd_for_tokens(tokens),
          token_balance: account.token_balance,
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
