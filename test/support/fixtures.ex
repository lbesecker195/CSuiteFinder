defmodule CsuiteFinder.Fixtures do
  @moduledoc "Test fixtures."

  alias CsuiteFinder.{Accounts, Billing}

  @doc """
  An account with a working key.

  Defaults to the developer audience: these fixtures back the API tests, and the
  API is the developer's half of the business. Pass `audience: "sales"` to
  exercise what a seat holder sees.
  """
  def account_with_key(opts \\ []) do
    email = Keyword.get(opts, :email, "acct#{System.unique_integer([:positive])}@test.com")

    {:ok, account} =
      Accounts.create_account(%{
        email: email,
        audience: Keyword.get(opts, :audience, "developer")
      })

    account =
      case Keyword.get(opts, :usd, 10.0) do
        usd when usd > 0 ->
          elem(Billing.credit(account, CsuiteFinder.Billing.Pricing.micro(usd)), 1)

        _ ->
          account
      end

    {:ok, key, _} = Accounts.create_api_key(account)
    {account, key}
  end
end
