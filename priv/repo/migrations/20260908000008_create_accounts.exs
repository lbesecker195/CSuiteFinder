defmodule CsuiteFinder.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :email, :citext, null: false
      add :name, :string
      # Prepaid balance in micro-USD, so provider costs land without rounding.
      add :balance_micro, :bigint, null: false, default: 0
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:accounts, [:email])

    create table(:api_keys) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      # Only the hash is stored; the plaintext key is shown once at creation.
      add :key_hash, :string, null: false
      add :prefix, :string, null: false
      add :label, :string
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:account_id])
  end
end
