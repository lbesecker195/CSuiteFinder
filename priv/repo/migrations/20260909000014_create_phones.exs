defmodule CsuiteFinder.Repo.Migrations.CreatePhones do
  use Ecto.Migration

  def change do
    create table(:phones) do
      # Digits with an optional leading +, so the same number written five ways
      # resolves to one row. `e164` holds the canonical form once a validator
      # has told us the country.
      add :phone, :citext, null: false
      add :e164, :citext

      # Who it belongs to, when we know. This is what makes the table a reverse
      # index: no provider in the catalog turns a phone back into a person, but
      # a number we found FOR someone is a number we can attribute later.
      add :email, :citext
      add :domain, :citext
      add :full_name, :string
      add :first_name, :string
      add :last_name, :string
      add :position, :string

      add :line_type, :string
      add :carrier, :string
      add :country_code, :string
      add :region, :string
      add :region_code, :string
      add :city, :string
      add :timezones, {:array, :string}, default: []

      add :valid, :boolean
      add :local_format, :string
      add :intl_format, :string
      add :rfc3966_format, :string
      add :validated_at, :utc_datetime_usec

      add :found, :boolean, null: false, default: false
      add :source, :string, null: false
      add :provider, :string
      add :provider_cost_micro, :integer, null: false, default: 0
      add :raw, :map
      add :expires_at, :utc_datetime_usec
      add :last_found_at, :utc_datetime_usec
      add :refresh_failures, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:phones, [:phone])
    create index(:phones, [:email])
    create index(:phones, [:domain])
    create index(:phones, [:e164])
  end
end
