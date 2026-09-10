defmodule CsuiteFinder.Repo.Migrations.PaymentKind do
  use Ecto.Migration

  def change do
    # What a payment buys, because the two land in different pools. A top-up is
    # credit bought outright and never expires; a seat trial is a month of the
    # seat and does. Capture has to know which without inferring it from the
    # amount.
    alter table(:payments) do
      add :kind, :string, null: false, default: "topup"
    end

    create index(:payments, [:kind])
  end
end
