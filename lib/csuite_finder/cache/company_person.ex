defmodule CsuiteFinder.Cache.CompanyPerson do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "company_people" do
    field :domain, :string
    field :email, :string
    field :full_name, :string
    field :first_name, :string
    field :last_name, :string
    field :position, :string
    field :department, :string
    field :seniority, :string
    field :linkedin_url, :string
    field :twitter, :string
    field :phone, :string
    field :kind, :string
    field :confidence, :float
    field :provider, :string
    field :raw, :map

    timestamps()
  end

  @fields ~w(domain email full_name first_name last_name position department seniority
             linkedin_url twitter phone kind confidence provider raw)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:domain, :email])
    |> update_change(:domain, &String.downcase/1)
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint([:domain, :email])
  end
end
