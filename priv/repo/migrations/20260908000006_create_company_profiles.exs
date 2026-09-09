defmodule CsuiteFinder.Repo.Migrations.CreateCompanyProfiles do
  use Ecto.Migration

  def change do
    create table(:company_profiles) do
      add :domain, :citext, null: false

      add :name, :string
      add :legal_name, :string
      add :description, :text
      add :industry, :string
      add :employee_count, :integer
      add :employee_range, :string
      add :founded_year, :integer
      add :revenue_range, :string
      add :country, :string
      add :city, :string
      add :website, :string
      add :linkedin_url, :string
      add :logo_url, :string
      add :tech_stack, {:array, :string}, default: []

      add :found, :boolean, null: false, default: false
      add :source, :string, null: false
      add :provider, :string
      add :provider_cost_micro, :integer, null: false, default: 0
      add :raw, :map
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:company_profiles, [:domain])
  end
end
