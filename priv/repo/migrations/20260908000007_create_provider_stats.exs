defmodule CsuiteFinder.Repo.Migrations.CreateProviderStats do
  use Ecto.Migration

  def change do
    # Append-only record of every provider attempt we (or treg's waterfall on our
    # behalf) made. `prior_failures` is how many providers had already missed on
    # this same query before this one was tried — a hit after three misses is
    # evidence about a much harder query than a hit on the first try, so the
    # aggregate weights it more heavily.
    create table(:provider_attempts) do
      add :capability, :string, null: false
      add :provider, :string, null: false
      add :hit, :boolean, null: false
      add :prior_failures, :integer, null: false, default: 0
      add :cost_micro, :integer, null: false, default: 0
      add :latency_ms, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:provider_attempts, [:capability, :provider])
    create index(:provider_attempts, [:inserted_at])

    # Rolling aggregate, kept in step with provider_attempts so the planner can
    # order providers with a single indexed read.
    create table(:provider_stats) do
      add :capability, :string, null: false
      add :provider, :string, null: false

      add :attempts, :integer, null: false, default: 0
      add :hits, :integer, null: false, default: 0
      # Difficulty-weighted counters: sum of (1 + prior_failures) over attempts/hits.
      add :weighted_attempts, :float, null: false, default: 0.0
      add :weighted_hits, :float, null: false, default: 0.0

      add :cost_micro_total, :integer, null: false, default: 0
      add :latency_ms_total, :integer, null: false, default: 0
      add :last_ok_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_stats, [:capability, :provider])
  end
end
