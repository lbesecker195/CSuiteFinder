defmodule CsuiteFinder.Billing.Subscription do
  @moduledoc """
  One team's seat subscription, mirrored from PayPal.

  PayPal is the source of truth for whether money moved; this row is what the
  app reads so a page render does not depend on a network call.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  # PayPal's own vocabulary, lower-cased, plus "pending" for a subscription that
  # exists but has not been approved by the payer yet.
  @statuses ~w(pending approval_pending approved active suspended cancelled expired)

  schema "subscriptions" do
    field :provider, :string, default: "paypal"
    field :interval, :string, default: "month"
    field :refreshed_for, :date
    field :provider_ref, :string
    field :provider_plan_id, :string
    field :seats, :integer, default: 1
    field :status, :string, default: "pending"
    field :grant_micro_per_period, :integer, default: 0
    field :current_period_end, :utc_datetime_usec
    field :last_payment_id, :string
    field :raw, :map

    belongs_to :account, CsuiteFinder.Accounts.Account

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :provider,
      :interval,
      :refreshed_for,
      :account_id,
      :provider_ref,
      :provider_plan_id,
      :seats,
      :status,
      :grant_micro_per_period,
      :current_period_end,
      :last_payment_id,
      :raw
    ])
    |> validate_required([:provider, :account_id, :provider_ref])
    |> validate_number(:seats, greater_than: 0, less_than_or_equal_to: 500)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:provider, :provider_ref])
  end

  @doc "Statuses that mean the subscription is paying and should be granting."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{status: status}), do: status == "active"

  @type t :: %__MODULE__{}
end
