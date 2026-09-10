defmodule CsuiteFinder.Repo.Migrations.PasswordLogin do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # Null means this account has no password and signs in with its key, which
      # is every account that existed before this. Setting one is optional and
      # always will be: the API itself is key-authenticated and passwords have
      # no part in it.
      add :password_hash, :string
      # Brute force is the whole risk of adding a password to a system that had
      # none, so failures are counted and the account is put out of reach for a
      # while once there are enough of them.
      add :failed_logins, :integer, null: false, default: 0
      add :locked_until, :utc_datetime_usec
    end

    alter table(:api_keys) do
      # "api" — a key the holder keeps, shown once, no expiry.
      # "session" — minted by a password login, expires on its own.
      add :kind, :string, null: false, default: "api"
      add :expires_at, :utc_datetime_usec
    end

    create index(:api_keys, [:kind])
  end
end
