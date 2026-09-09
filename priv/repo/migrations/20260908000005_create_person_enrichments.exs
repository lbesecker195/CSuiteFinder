defmodule CsuiteFinder.Repo.Migrations.CreatePersonEnrichments do
  use Ecto.Migration

  def change do
    create table(:person_enrichments) do
      add :email, :citext, null: false
      add :domain, :citext, null: false

      add :full_name, :string
      add :first_name, :string
      add :last_name, :string
      add :position, :string
      add :seniority, :string
      add :department, :string
      add :company_name, :string
      add :linkedin_url, :string
      add :twitter, :string
      add :location, :string
      add :phone, :string

      add :found, :boolean, null: false, default: false
      # "provider" when a real lookup answered; "inferred" when we derived it
      # locally from the address itself and nothing verified it.
      add :source, :string, null: false
      add :confidence, :string
      add :provider, :string
      add :provider_cost_micro, :integer, null: false, default: 0
      add :raw, :map
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:person_enrichments, [:email])
    create index(:person_enrichments, [:domain])
  end
end
