defmodule CsuiteFinder.Billing.Payment do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "payments" do
    field :paypal_order_id, :string
    field :paypal_capture_id, :string
    field :amount_micro, :integer
    field :credit_micro, :integer, default: 0
    field :currency, :string, default: "USD"
    field :status, :string, default: "created"
    # "topup" (permanent credit) or "seat_trial" (a month of the seat).
    field :kind, :string, default: "topup"
    field :credited_at, :utc_datetime_usec
    field :raw, :map

    belongs_to :account, CsuiteFinder.Accounts.Account

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :account_id,
      :paypal_order_id,
      :paypal_capture_id,
      :amount_micro,
      :credit_micro,
      :currency,
      :status,
      :kind,
      :credited_at,
      :raw
    ])
    |> validate_required([:account_id, :paypal_order_id, :amount_micro])
    |> validate_inclusion(:status, ~w(created approved captured credited failed))
    |> validate_inclusion(:kind, ~w(topup seat_trial))
    |> unique_constraint(:paypal_order_id)
  end
end
