defmodule CsuiteFinder.Repo.Migrations.GrantedCredit do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # Credit that expires: a seat's monthly allowance, or the free trial.
      # Kept apart from `balance_micro` — purchased credit — because the two
      # have different lifetimes and spending the wrong one first would quietly
      # waste the customer's money.
      add :granted_micro, :bigint, null: false, default: 0
      add :granted_expires_at, :utc_datetime_usec
    end

    create index(:accounts, [:granted_expires_at])

    # Existing trial credit becomes granted credit with a month to run, so no
    # one loses what they were given. Anything above the trial was bought, and
    # bought credit does not expire.
    execute(
      """
      UPDATE accounts
         SET granted_micro = LEAST(balance_micro, 1000000),
             balance_micro = balance_micro - LEAST(balance_micro, 1000000),
             granted_expires_at = NOW() + INTERVAL '30 days'
       WHERE trial_granted_at IS NOT NULL
      """,
      """
      UPDATE accounts
         SET balance_micro = balance_micro + granted_micro,
             granted_micro = 0,
             granted_expires_at = NULL
      """
    )
  end
end
