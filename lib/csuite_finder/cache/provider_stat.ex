defmodule CsuiteFinder.Cache.ProviderStat do
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "provider_stats" do
    field :capability, :string
    field :provider, :string
    field :attempts, :integer, default: 0
    field :hits, :integer, default: 0
    field :weighted_attempts, :float, default: 0.0
    field :weighted_hits, :float, default: 0.0
    field :cost_micro_total, :integer, default: 0
    field :latency_ms_total, :integer, default: 0
    field :last_ok_at, :utc_datetime_usec

    timestamps()
  end
end
