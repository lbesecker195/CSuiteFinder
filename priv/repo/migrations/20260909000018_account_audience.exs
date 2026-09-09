defmodule CsuiteFinder.Repo.Migrations.AccountAudience do
  use Ecto.Migration

  def change do
    # Which half of the business this account belongs to. It decides what the
    # site shows them — seat pricing or per-answer pricing — so it is never
    # null and never anything but a known value.
    alter table(:accounts) do
      add :audience, :string, null: false, default: "sales"
    end

    create constraint(:accounts, :audience_known, check: "audience IN ('sales', 'developer')")
    create index(:accounts, [:audience])

    # Every account that existed before this column came in through the API —
    # there was no other way to sign up — so anyone who has actually called it
    # is a developer. The rest keep the default, which is the price that is safe
    # to show to anybody.
    execute(
      """
      UPDATE accounts SET audience = 'developer'
       WHERE id IN (SELECT DISTINCT account_id FROM usage_events WHERE account_id IS NOT NULL)
      """,
      "UPDATE accounts SET audience = 'sales'"
    )
  end
end
