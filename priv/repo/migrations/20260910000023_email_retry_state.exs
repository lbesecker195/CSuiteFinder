defmodule CsuiteFinder.Repo.Migrations.EmailRetryState do
  use Ecto.Migration

  def change do
    alter table(:emails) do
      # Addresses proved wrong for THIS person. A retry must not rebuild one we
      # have already been told does not exist, and without a record of them it
      # would: the pattern that produced it is still the company's pattern.
      add :rejected, {:array, :string}, null: false, default: []
      # Whether the paid lookup has been spent on this person yet. It is the
      # difference between "worth asking again" and "we have asked everyone".
      add :provider_tried, :boolean, null: false, default: false
    end
  end
end
