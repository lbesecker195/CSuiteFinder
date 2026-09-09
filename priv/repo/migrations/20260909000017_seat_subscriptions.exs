defmodule CsuiteFinder.Repo.Migrations.SeatSubscriptions do
  use Ecto.Migration

  def change do
    # PayPal wants a product and a billing plan created once, up front, and then
    # referenced by id forever. Storing the ids means we create them on the
    # first subscription and never again — and `key` carries the price, so a
    # price change makes a new plan instead of silently reusing the old amount.
    create table(:paypal_plans) do
      add :key, :string, null: false
      add :paypal_product_id, :string
      add :paypal_plan_id, :string, null: false
      add :amount_micro, :bigint, null: false
      add :raw, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:paypal_plans, [:key])

    create table(:subscriptions) do
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :paypal_subscription_id, :string, null: false
      add :paypal_plan_id, :string
      add :seats, :integer, null: false, default: 1
      add :status, :string, null: false, default: "pending"
      # What one period grants. Held per subscription rather than read from the
      # price list at grant time, so a price rise does not retroactively change
      # what an existing subscriber is owed for the month they already paid.
      add :grant_micro_per_period, :bigint, null: false, default: 0
      add :current_period_end, :utc_datetime_usec
      # The last payment we granted for. PayPal retries webhooks; this is what
      # stops one month's payment being granted twice.
      add :last_payment_id, :string
      add :raw, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subscriptions, [:paypal_subscription_id])
    create index(:subscriptions, [:account_id])
  end
end
