defmodule CsuiteFinder.Repo.Migrations.CreateEmails do
  use Ecto.Migration

  def change do
    create table(:emails) do
      # Cache key: the normalized person + company.
      add :name_key, :string, null: false
      add :domain, :citext, null: false

      add :full_name, :string, null: false
      add :first_name, :string
      add :last_name, :string

      add :email, :citext
      add :found, :boolean, null: false, default: false
      # "pattern" (built locally from a cached/looked-up pattern) | "treg" | "cache"
      add :source, :string, null: false
      add :pattern_used, :string
      add :confidence, :float
      add :verification_status, :string
      add :provider, :string
      add :provider_cost_micro, :integer, null: false, default: 0
      add :raw, :map
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:emails, [:name_key, :domain])
    create index(:emails, [:domain])
    create index(:emails, [:email])
  end
end
