defmodule CsuiteFinder.Repo.Migrations.CompanySearches do
  use Ecto.Migration

  def change do
    # A search remembers only which companies it returned, in order. The
    # companies themselves are rows in company_profiles, so a domain found by a
    # search is the same row /company/info later reads and enriches — one
    # company, one record, however it was discovered.
    create table(:company_searches) do
      # sha256 of the normalised filters, so the same question asked twice is
      # one purchase however the parameters were spelled or ordered.
      add :fingerprint, :string, null: false
      add :filters, :map, null: false, default: %{}
      add :domains, {:array, :string}, null: false, default: []
      add :total, :integer, null: false, default: 0
      add :found, :boolean, null: false, default: false
      add :provider, :string
      add :provider_cost_micro, :bigint, null: false, default: 0
      add :raw, :map
      add :expires_at, :utc_datetime_usec
      add :last_found_at, :utc_datetime_usec
      add :refresh_failures, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:company_searches, [:fingerprint])
  end
end
