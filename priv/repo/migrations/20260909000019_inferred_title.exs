defmodule CsuiteFinder.Repo.Migrations.InferredTitle do
  use Ecto.Migration

  def change do
    # Where the job title came from. A title a provider stated and a title a
    # model guessed are worth different amounts to whoever is about to open an
    # email with it, so the row remembers which it was rather than letting a
    # guess inherit the provider's credibility.
    alter table(:person_enrichments) do
      add :position_source, :string
    end
  end
end
