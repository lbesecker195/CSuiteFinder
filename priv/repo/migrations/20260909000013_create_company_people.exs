defmodule CsuiteFinder.Repo.Migrations.CreateCompanyPeople do
  use Ecto.Migration

  def change do
    # One row per PERSON rather than per query. A search for engineering at
    # acme.com and a later search for executives there share these rows, and a
    # narrower query is answered from what a broader one already paid for.
    create table(:company_people) do
      add :domain, :citext, null: false
      add :email, :citext, null: false

      add :full_name, :string
      add :first_name, :string
      add :last_name, :string
      add :position, :string
      add :department, :string
      add :seniority, :string
      add :linkedin_url, :string
      add :twitter, :string
      add :phone, :string
      # "personal" (a named human) or "generic" (sales@, info@).
      add :kind, :string
      add :confidence, :float

      add :provider, :string
      add :raw, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:company_people, [:domain, :email])
    create index(:company_people, [:domain, :department])

    alter table(:company_profiles) do
      # When we last swept this domain for people, and how many the provider
      # said exist. Together they decide whether a request can be served from
      # the rows above or needs another page bought.
      add :people_fetched_at, :utc_datetime_usec
      add :people_total, :integer
    end
  end
end
