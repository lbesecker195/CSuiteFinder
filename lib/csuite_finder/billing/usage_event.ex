defmodule CsuiteFinder.Billing.UsageEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "usage_events" do
    field :endpoint, :string
    field :cache_hit, :boolean, default: false
    field :outcome, :string
    field :provider_cost_micro, :integer, default: 0
    field :charged_tokens, :integer, default: 0
    field :request, :map
    field :treg_call_ids, {:array, :string}, default: []

    belongs_to :account, CsuiteFinder.Accounts.Account
    belongs_to :api_key, CsuiteFinder.Accounts.ApiKey

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :account_id,
      :api_key_id,
      :endpoint,
      :cache_hit,
      :outcome,
      :provider_cost_micro,
      :charged_tokens,
      :request,
      :treg_call_ids
    ])
    |> validate_required([:endpoint, :outcome])
  end
end
