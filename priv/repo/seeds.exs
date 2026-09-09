# Registers a demo account and prints its API key.
#
#     mix run priv/repo/seeds.exs
#
# Registration grants the standard free trial. Pass SEED_TOKENS to top it up
# beyond the trial for local work.
alias CsuiteFinder.{Accounts, Billing, Repo}
alias CsuiteFinder.Billing.Pricing

email = System.get_env("SEED_EMAIL") || "demo@csuitefinder.test"

{account, key} =
  case Repo.get_by(Accounts.Account, email: email) do
    nil ->
      {:ok, %{account: account, api_key: key}} = Accounts.register(%{email: email, name: "Demo"})
      {account, key}

    existing ->
      {:ok, key, _} = Accounts.create_api_key(existing, "seed key")
      {existing, key}
  end

account =
  case System.get_env("SEED_TOKENS") do
    nil -> account
    tokens -> elem(Billing.credit(account, String.to_integer(tokens)), 1)
  end

IO.puts("""

  account_id : #{account.id}
  email      : #{account.email}
  tokens     : #{account.token_balance} (#{Pricing.usd_for_tokens(account.token_balance)} USD)
  api_key    : #{key}
""")
