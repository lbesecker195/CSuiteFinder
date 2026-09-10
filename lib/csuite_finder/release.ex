defmodule CsuiteFinder.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :csuite_finder

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Put credit on an account by hand, in whole dollars.

  For the cases a PayPal capture cannot cover: a customer paid another way, or
  someone is owed a refund of credit rather than money.

  It goes through `CsuiteFinder.Billing.credit/2` rather than an UPDATE, which
  is the point of it existing. Credit lives in two columns with different
  lifetimes, and a hand-written UPDATE into `granted_micro` would quietly hand
  someone a balance that expires at the end of the month. This always credits
  the purchased pool, which never expires — the same place a payment lands.

      bin/csuite_finder eval 'CsuiteFinder.Release.credit("me@example.com", 1000)'

  Prints the balance before and after, and refuses rather than guesses when the
  address is not on an account.
  """
  def credit(email, usd) when is_binary(email) and is_number(usd) and usd > 0 do
    start_app()

    email = String.downcase(String.trim(email))

    case CsuiteFinder.Repo.get_by(CsuiteFinder.Accounts.Account, email: email) do
      nil ->
        IO.puts("No account for #{email}. Nothing changed.")
        :error

      account ->
        before = CsuiteFinder.Billing.available_micro(account)

        {:ok, updated} =
          CsuiteFinder.Billing.credit(account, CsuiteFinder.Billing.Pricing.micro(usd))

        IO.puts("""
        #{email}
          before   $#{CsuiteFinder.Billing.Pricing.usd(before)}
          credited $#{usd}
          after    $#{CsuiteFinder.Billing.Pricing.usd(CsuiteFinder.Billing.available_micro(updated))} \
        (purchased $#{CsuiteFinder.Billing.Pricing.usd(updated.balance_micro)}, \
        granted $#{CsuiteFinder.Billing.Pricing.usd(CsuiteFinder.Billing.live_grant_micro(updated))})
        """)

        {:ok, updated}
    end
  end

  defp start_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
