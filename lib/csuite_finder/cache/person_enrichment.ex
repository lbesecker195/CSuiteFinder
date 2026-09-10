defmodule CsuiteFinder.Cache.PersonEnrichment do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "person_enrichments" do
    field :email, :string
    field :domain, :string
    field :full_name, :string
    field :first_name, :string
    field :last_name, :string
    field :position, :string
    # "provider" or "inferred" — see CsuiteFinder.Inference.
    field :position_source, :string
    field :seniority, :string
    field :department, :string
    field :company_name, :string
    field :linkedin_url, :string
    field :twitter, :string
    field :location, :string
    field :phone, :string
    field :found, :boolean, default: false
    field :source, :string
    field :confidence, :string
    field :provider, :string
    field :provider_cost_micro, :integer, default: 0
    field :raw, :map
    field :expires_at, :utc_datetime_usec
    field :last_found_at, :utc_datetime_usec
    field :refresh_failures, :integer, default: 0

    timestamps()
  end

  @fields ~w(email domain full_name first_name last_name position position_source seniority department
             company_name linkedin_url twitter location phone found source confidence
             provider provider_cost_micro raw expires_at last_found_at refresh_failures)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:email, :domain, :source])
    |> validate_inclusion(:source, ~w(provider inferred))
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
  end
end
