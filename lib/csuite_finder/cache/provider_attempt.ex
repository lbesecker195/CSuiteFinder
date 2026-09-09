defmodule CsuiteFinder.Cache.ProviderAttempt do
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "provider_attempts" do
    field :capability, :string
    field :provider, :string
    field :hit, :boolean
    field :prior_failures, :integer, default: 0
    field :cost_micro, :integer, default: 0
    field :latency_ms, :integer

    timestamps()
  end
end
