defmodule CsuiteFinder.Repo.Migrations.TokensAndDurableCache do
  use Ecto.Migration

  # $0.0025 per token.
  @micro_per_token 2_500

  def up do
    # --- Billing moves from micro-USD to tokens ----------------------------
    alter table(:accounts) do
      add :token_balance, :bigint, null: false, default: 0
      add :trial_granted_at, :utc_datetime_usec
    end

    # Convert any existing prepaid balance at the token rate rather than
    # dropping it on the floor.
    execute "UPDATE accounts SET token_balance = balance_micro / #{@micro_per_token}"

    alter table(:accounts) do
      remove :balance_micro
    end

    alter table(:payments) do
      add :tokens, :bigint, null: false, default: 0
    end

    execute "UPDATE payments SET tokens = amount_micro / #{@micro_per_token}"

    alter table(:usage_events) do
      add :charged_tokens, :integer, null: false, default: 0
    end

    execute "UPDATE usage_events SET charged_tokens = charged_micro / #{@micro_per_token}"

    alter table(:usage_events) do
      remove :charged_micro
    end

    # --- Cache rows keep their last known good value forever ----------------
    #
    # `expires_at` still decides when we go and look again. What changes is what
    # happens when that refresh comes back empty: `last_found_at` records when we
    # last actually held data, and `refresh_failures` counts the consecutive
    # attempts since, so a row can be served as known-but-stale instead of being
    # overwritten with the nothing we just got.
    # Verifications record a verdict rather than a `found` flag: any verdict
    # other than "unknown" is real data we should not lose.
    backfills = [
      {:email_patterns, "found = true"},
      {:emails, "found = true"},
      {:email_verifications, "status <> 'unknown'"},
      {:person_enrichments, "found = true"},
      {:company_profiles, "found = true"}
    ]

    for {table, known_predicate} <- backfills do
      alter table(table) do
        add :last_found_at, :utc_datetime_usec
        add :refresh_failures, :integer, null: false, default: 0
      end

      execute "UPDATE #{table} SET last_found_at = updated_at WHERE #{known_predicate}"
    end
  end

  def down do
    alter table(:accounts) do
      add :balance_micro, :bigint, null: false, default: 0
    end

    execute "UPDATE accounts SET balance_micro = token_balance * #{@micro_per_token}"

    alter table(:accounts) do
      remove :token_balance
      remove :trial_granted_at
    end

    alter table(:usage_events) do
      add :charged_micro, :integer, null: false, default: 0
    end

    execute "UPDATE usage_events SET charged_micro = charged_tokens * #{@micro_per_token}"

    alter table(:usage_events) do
      remove :charged_tokens
    end

    alter table(:payments) do
      remove :tokens
    end

    for table <- [
          :email_patterns,
          :emails,
          :email_verifications,
          :person_enrichments,
          :company_profiles
        ] do
      alter table(table) do
        remove :last_found_at
        remove :refresh_failures
      end
    end
  end
end
