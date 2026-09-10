defmodule CsuiteFinder.Cache.PeopleSearch do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "people_searches" do
    field :fingerprint, :string
    field :filters, :map, default: %{}
    field :results, {:array, :map}, default: []
    field :total, :integer, default: 0
    field :found, :boolean, default: false
    field :provider, :string
    field :provider_cost_micro, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :last_found_at, :utc_datetime_usec
    field :refresh_failures, :integer, default: 0

    timestamps()
  end

  @fields ~w(fingerprint filters results total found provider provider_cost_micro
             expires_at last_found_at refresh_failures)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:fingerprint])
    |> unique_constraint(:fingerprint)
  end

  @type t :: %__MODULE__{}
end
