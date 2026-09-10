defmodule CsuiteFinder.Repo.Migrations.PeopleSearches do
  use Ecto.Migration

  def change do
    # Unlike a company search, the rows are stored inline rather than as
    # reusable records. A company has a domain to key on; a person found by a
    # title search often has no email and no stable identifier at all, and
    # inventing one would merge two people the first time two Jane Smiths turn
    # up at the same employer.
    create table(:people_searches) do
      add :fingerprint, :string, null: false
      add :filters, :map, null: false, default: %{}
      add :results, {:array, :map}, null: false, default: []
      add :total, :integer, null: false, default: 0
      add :found, :boolean, null: false, default: false
      add :provider, :string
      add :provider_cost_micro, :bigint, null: false, default: 0
      add :expires_at, :utc_datetime_usec
      add :last_found_at, :utc_datetime_usec
      add :refresh_failures, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:people_searches, [:fingerprint])
  end
end
