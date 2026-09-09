defmodule CsuiteFinder.Repo.Migrations.CreateEmailPatterns do
  use Ecto.Migration

  def change do
    create table(:email_patterns) do
      add :domain, :citext, null: false
      # Canonical pattern in our own token language, e.g. "{first}.{last}"
      add :pattern, :string
      # Every candidate the provider returned, with usage percentages.
      add :candidates, :map, null: false, default: %{}
      add :confidence, :float
      # "thecompaniesapi" | "derived" | "observed" — where the winning pattern came from.
      add :source, :string, null: false
      # Negative caching: a domain we looked up and genuinely could not pattern.
      add :found, :boolean, null: false, default: false
      add :provider_cost_micro, :integer, null: false, default: 0
      add :raw, :map
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_patterns, [:domain])
    create index(:email_patterns, [:expires_at])
  end
end
