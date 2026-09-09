defmodule CsuiteFinder.Repo.Migrations.AddKeyRecovery do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # Stamped when a recovery link is issued, and cleared the moment one is
      # redeemed. The signed link carries this timestamp, so redeeming it makes
      # every outstanding link for the account stop verifying — which is what
      # turns a stateless signed token into a genuinely single-use one.
      add :key_recovery_at, :utc_datetime_usec
    end
  end
end
