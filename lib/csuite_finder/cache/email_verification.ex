defmodule CsuiteFinder.Cache.EmailVerification do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "email_verifications" do
    field :email, :string
    field :domain, :string
    field :status, :string
    field :sub_status, :string
    field :score, :float
    field :catch_all, :boolean
    field :disposable, :boolean
    field :role_account, :boolean
    field :free_provider, :boolean
    field :mx_found, :boolean
    field :smtp_check, :boolean
    field :provider, :string
    field :provider_cost_micro, :integer, default: 0
    field :raw, :map
    field :expires_at, :utc_datetime_usec
    field :last_found_at, :utc_datetime_usec
    field :refresh_failures, :integer, default: 0

    timestamps()
  end

  @fields ~w(email domain status sub_status score catch_all disposable role_account
             free_provider mx_found smtp_check provider provider_cost_micro raw expires_at last_found_at refresh_failures)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:email, :domain, :status])
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
  end
end
