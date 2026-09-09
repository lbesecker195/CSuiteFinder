defmodule CsuiteFinder.Repo.Migrations.CreateUsageAndPayments do
  use Ecto.Migration

  def change do
    # One row per billable API request: what it cost us upstream, what we
    # charged, and whether the cache absorbed it.
    create table(:usage_events) do
      add :account_id, references(:accounts, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, on_delete: :nilify_all)
      add :endpoint, :string, null: false
      add :cache_hit, :boolean, null: false, default: false
      add :outcome, :string, null: false
      add :provider_cost_micro, :integer, null: false, default: 0
      add :charged_micro, :integer, null: false, default: 0
      add :request, :map
      add :treg_call_ids, {:array, :string}, default: []

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:usage_events, [:account_id, :inserted_at])
    create index(:usage_events, [:endpoint])

    # PayPal top-ups. `paypal_order_id` is unique so a replayed capture webhook
    # cannot credit the same order twice.
    create table(:payments) do
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :paypal_order_id, :string, null: false
      add :paypal_capture_id, :string
      add :amount_micro, :bigint, null: false
      add :currency, :string, null: false, default: "USD"
      add :status, :string, null: false, default: "created"
      add :credited_at, :utc_datetime_usec
      add :raw, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:payments, [:paypal_order_id])
    create index(:payments, [:account_id])
  end
end
