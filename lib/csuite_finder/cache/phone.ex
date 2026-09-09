defmodule CsuiteFinder.Cache.Phone do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "phones" do
    field :phone, :string
    field :e164, :string
    field :email, :string
    field :domain, :string
    field :full_name, :string
    field :first_name, :string
    field :last_name, :string
    field :position, :string
    field :line_type, :string
    field :carrier, :string
    field :country_code, :string
    field :region, :string
    field :region_code, :string
    field :city, :string
    field :timezones, {:array, :string}, default: []
    field :valid, :boolean
    field :local_format, :string
    field :intl_format, :string
    field :rfc3966_format, :string
    field :validated_at, :utc_datetime_usec
    field :found, :boolean, default: false
    field :source, :string
    field :provider, :string
    field :provider_cost_micro, :integer, default: 0
    field :raw, :map
    field :expires_at, :utc_datetime_usec
    field :last_found_at, :utc_datetime_usec
    field :refresh_failures, :integer, default: 0

    timestamps()
  end

  @fields ~w(phone e164 email domain full_name first_name last_name position line_type
             carrier country_code region region_code city timezones valid local_format
             intl_format rfc3966_format validated_at found source provider
             provider_cost_micro raw expires_at last_found_at refresh_failures)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:phone, :source])
    |> update_change(:phone, &String.downcase/1)
    |> unique_constraint(:phone)
  end
end
