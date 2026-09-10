defmodule CsuiteFinder.Repo.Migrations.LinkedinEmailLookup do
  use Ecto.Migration

  def change do
    # A LinkedIn profile is a second way into the same row. The address is still
    # keyed by name and domain — that is what makes it reusable by the cheap
    # path — but a profile URL that has resolved once must not be bought twice,
    # so it gets its own index into the same table.
    alter table(:emails) do
      add :linkedin_url, :string
    end

    create index(:emails, [:linkedin_url])
  end
end
