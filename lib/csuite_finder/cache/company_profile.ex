defmodule CsuiteFinder.Cache.CompanyProfile do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "company_profiles" do
    field :domain, :string
    field :name, :string
    field :legal_name, :string
    field :description, :string
    field :industry, :string
    field :employee_count, :integer
    field :employee_range, :string
    field :founded_year, :integer
    field :revenue_range, :string
    field :country, :string
    field :city, :string
    field :website, :string
    field :linkedin_url, :string
    field :logo_url, :string
    field :tech_stack, {:array, :string}, default: []
    field :found, :boolean, default: false
    field :source, :string
    field :provider, :string
    field :provider_cost_micro, :integer, default: 0
    field :raw, :map
    field :expires_at, :utc_datetime_usec
    field :people_fetched_at, :utc_datetime_usec
    field :people_total, :integer
    field :last_found_at, :utc_datetime_usec
    field :refresh_failures, :integer, default: 0

    timestamps()
  end

  @fields ~w(domain name legal_name description industry employee_count employee_range
             founded_year revenue_range country city website linkedin_url logo_url
             tech_stack found source provider provider_cost_micro raw expires_at last_found_at refresh_failures people_fetched_at people_total)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:domain, :source])
    |> update_change(:domain, &String.downcase/1)
    |> unique_constraint(:domain)
  end
end
