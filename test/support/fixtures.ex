defmodule CsuiteFinder.Fixtures do
  @moduledoc "Test fixtures."

  alias CsuiteFinder.{Accounts, Billing}

  def account_with_key(opts \\ []) do
    email = Keyword.get(opts, :email, "acct#{System.unique_integer([:positive])}@test.com")
    {:ok, account} = Accounts.create_account(%{email: email})

    account =
      case Keyword.get(opts, :tokens, 4_000) do
        0 -> account
        tokens -> elem(Billing.credit(account, tokens), 1)
      end

    {:ok, key, _} = Accounts.create_api_key(account)
    {account, key}
  end
end
