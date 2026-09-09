defmodule CsuiteFinder.Repo.Migrations.AddRequestDuration do
  use Ecto.Migration

  def change do
    alter table(:usage_events) do
      # End-to-end wall time for the request, in milliseconds — what the caller
      # actually waited, not just what an upstream took. The two differ by the
      # cache: a cached answer spends no provider time at all.
      add :duration_ms, :integer
    end

    create index(:usage_events, [:endpoint, :duration_ms])
  end
end
