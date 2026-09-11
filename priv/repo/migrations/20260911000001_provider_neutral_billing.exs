defmodule CsuiteFinder.Repo.Migrations.ProviderNeutralBilling do
  @moduledoc """
  Take PayPal's name off the billing tables.

  These columns held a PayPal order id because PayPal was the only processor.
  A column called `paypal_order_id` holding a Stripe session id is the kind of
  thing that is still lying to the next reader two years later, and renaming it
  once now costs nothing — there are no subscriptions and no plans yet.

  `provider` is added rather than assumed: the rows that exist were PayPal's,
  and a row has to be able to say which processor it came from, or a refund
  goes to the wrong API.
  """

  use Ecto.Migration

  def up do
    alter table(:payments) do
      add :provider, :string, null: false, default: "paypal"
    end

    rename table(:payments), :paypal_order_id, to: :provider_ref
    rename table(:payments), :paypal_capture_id, to: :provider_txn_id

    alter table(:subscriptions) do
      add :provider, :string, null: false, default: "paypal"
    end

    rename table(:subscriptions), :paypal_subscription_id, to: :provider_ref
    rename table(:subscriptions), :paypal_plan_id, to: :provider_plan_id

    rename table(:paypal_plans), to: table(:billing_plans)

    alter table(:billing_plans) do
      add :provider, :string, null: false, default: "paypal"
    end

    rename table(:billing_plans), :paypal_product_id, to: :provider_product_id
    rename table(:billing_plans), :paypal_plan_id, to: :provider_plan_id

    # The uniqueness that stops a replayed webhook crediting twice has to follow
    # the rename, and it is now per provider: two processors can legitimately
    # issue the same-looking reference.
    drop_if_exists unique_index(:payments, [:paypal_order_id])
    drop_if_exists unique_index(:subscriptions, [:paypal_subscription_id])
    drop_if_exists unique_index(:paypal_plans, [:key])

    create unique_index(:payments, [:provider, :provider_ref])
    create unique_index(:subscriptions, [:provider, :provider_ref])
    create unique_index(:billing_plans, [:provider, :key])
  end

  def down do
    drop_if_exists unique_index(:payments, [:provider, :provider_ref])
    drop_if_exists unique_index(:subscriptions, [:provider, :provider_ref])
    drop_if_exists unique_index(:billing_plans, [:provider, :key])

    rename table(:billing_plans), :provider_plan_id, to: :paypal_plan_id
    rename table(:billing_plans), :provider_product_id, to: :paypal_product_id

    alter table(:billing_plans) do
      remove :provider
    end

    rename table(:billing_plans), to: table(:paypal_plans)

    rename table(:subscriptions), :provider_plan_id, to: :paypal_plan_id
    rename table(:subscriptions), :provider_ref, to: :paypal_subscription_id

    alter table(:subscriptions) do
      remove :provider
    end

    rename table(:payments), :provider_txn_id, to: :paypal_capture_id
    rename table(:payments), :provider_ref, to: :paypal_order_id

    alter table(:payments) do
      remove :provider
    end

    create unique_index(:payments, [:paypal_order_id])
    create unique_index(:subscriptions, [:paypal_subscription_id])
    create unique_index(:paypal_plans, [:key])
  end
end
