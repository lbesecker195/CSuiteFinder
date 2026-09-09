defmodule CsuiteFinder.Cache.EmailPattern do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "email_patterns" do
    field :domain, :string
    field :pattern, :string
    field :candidates, :map, default: %{}
    field :confidence, :float
    field :source, :string
    field :found, :boolean, default: false
    field :provider_cost_micro, :integer, default: 0
    field :raw, :map
    field :expires_at, :utc_datetime_usec
    field :last_found_at, :utc_datetime_usec
    field :refresh_failures, :integer, default: 0

    timestamps()
  end

  @fields ~w(domain pattern candidates confidence source found provider_cost_micro raw expires_at last_found_at refresh_failures)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:domain, :source])
    |> update_change(:domain, &String.downcase/1)
    |> unique_constraint(:domain)
  end
end
