defmodule CsuiteFinder.Cache.Email do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "emails" do
    field :name_key, :string
    field :domain, :string
    field :full_name, :string
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    # The profile this row was resolved from, when it came in that way. A
    # second index into the same address, not a second address.
    field :linkedin_url, :string
    # Addresses disproved for this person, and whether the paid lookup has been
    # spent on them. Together they decide whether asking again can find
    # anything new — see CsuiteFinder.Finder.
    field :rejected, {:array, :string}, default: []
    field :provider_tried, :boolean, default: false
    field :found, :boolean, default: false
    field :source, :string
    field :pattern_used, :string
    field :confidence, :float
    field :verification_status, :string
    field :provider, :string
    field :provider_cost_micro, :integer, default: 0
    field :raw, :map
    field :expires_at, :utc_datetime_usec
    field :last_found_at, :utc_datetime_usec
    field :refresh_failures, :integer, default: 0

    timestamps()
  end

  @fields ~w(name_key domain full_name first_name last_name email linkedin_url
             rejected provider_tried found source
             pattern_used confidence verification_status provider
             provider_cost_micro raw expires_at last_found_at refresh_failures)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:name_key, :domain, :full_name, :source])
    |> update_change(:domain, &String.downcase/1)
    |> unique_constraint([:name_key, :domain])
  end
end
