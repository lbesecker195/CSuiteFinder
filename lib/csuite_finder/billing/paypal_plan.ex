defmodule CsuiteFinder.Billing.PayPalPlan do
  @moduledoc """
  A PayPal product + billing plan we created, remembered by its ids.

  PayPal plans are created once and referenced forever. `key` encodes the price
  and interval, so changing the seat price creates a new plan rather than
  quietly reusing one that bills the old amount.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "paypal_plans" do
    field :key, :string
    field :paypal_product_id, :string
    field :paypal_plan_id, :string
    field :amount_micro, :integer
    field :raw, :map

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:key, :paypal_product_id, :paypal_plan_id, :amount_micro, :raw])
    |> validate_required([:key, :paypal_plan_id, :amount_micro])
    |> unique_constraint(:key)
  end
end
