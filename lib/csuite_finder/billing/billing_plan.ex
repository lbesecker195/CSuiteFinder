defmodule CsuiteFinder.Billing.BillingPlan do
  @moduledoc """
  A recurring plan we created at a payment processor, remembered by its ids.

  A plan is created once and referenced forever. `key` encodes the price and
  interval, so changing the seat price creates a new plan rather than quietly
  reusing one that bills the old amount — and `provider` is part of its
  uniqueness, because the same key at two processors is two different plans.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "billing_plans" do
    field :provider, :string, default: "paypal"
    field :key, :string
    field :provider_product_id, :string
    field :provider_plan_id, :string
    field :amount_micro, :integer
    field :raw, :map

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:provider, :key, :provider_product_id, :provider_plan_id, :amount_micro, :raw])
    |> validate_required([:provider, :key, :provider_plan_id, :amount_micro])
    |> unique_constraint([:provider, :key])
  end
end
