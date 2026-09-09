defmodule CsuiteFinder.Repo.Migrations.CreateEmailVerifications do
  use Ecto.Migration

  def change do
    create table(:email_verifications) do
      add :email, :citext, null: false
      add :domain, :citext, null: false
      # deliverable | undeliverable | risky | unknown
      add :status, :string, null: false
      add :sub_status, :string
      add :score, :float
      add :catch_all, :boolean
      add :disposable, :boolean
      add :role_account, :boolean
      add :free_provider, :boolean
      add :mx_found, :boolean
      add :smtp_check, :boolean
      add :provider, :string
      add :provider_cost_micro, :integer, null: false, default: 0
      add :raw, :map
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_verifications, [:email])
    create index(:email_verifications, [:domain])
  end
end
