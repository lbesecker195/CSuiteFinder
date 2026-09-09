defmodule CsuiteFinder.Repo.Migrations.PriceInDollars do
  use Ecto.Migration

  # What a token was worth. Every conversion below is at this rate, so no
  # customer's balance changes value across the migration.
  @micro_per_token 2_500

  def up do
    alter table(:accounts) do
      add :balance_micro, :bigint, null: false, default: 0
    end

    execute "UPDATE accounts SET balance_micro = token_balance * #{@micro_per_token}"

    alter table(:accounts) do
      remove :token_balance
    end

    alter table(:usage_events) do
      add :charged_micro, :integer, null: false, default: 0
    end

    execute "UPDATE usage_events SET charged_micro = charged_tokens * #{@micro_per_token}"

    alter table(:usage_events) do
      remove :charged_tokens
    end

    # A bundle now buys credit rather than tokens, and larger bundles buy more
    # credit than they cost — the volume discount that used to live in the token
    # rate. Existing payments convert at the old rate, so what was bought stays
    # worth what it was worth.
    alter table(:payments) do
      add :credit_micro, :bigint, null: false, default: 0
    end

    execute "UPDATE payments SET credit_micro = tokens * #{@micro_per_token}"

    alter table(:payments) do
      remove :tokens
    end
  end

  def down do
    alter table(:accounts) do
      add :token_balance, :bigint, null: false, default: 0
    end

    execute "UPDATE accounts SET token_balance = balance_micro / #{@micro_per_token}"

    alter table(:accounts) do
      remove :balance_micro
    end

    alter table(:usage_events) do
      add :charged_tokens, :integer, null: false, default: 0
    end

    execute "UPDATE usage_events SET charged_tokens = charged_micro / #{@micro_per_token}"

    alter table(:usage_events) do
      remove :charged_micro
    end

    alter table(:payments) do
      add :tokens, :bigint, null: false, default: 0
    end

    execute "UPDATE payments SET tokens = credit_micro / #{@micro_per_token}"

    alter table(:payments) do
      remove :credit_micro
    end
  end
end
