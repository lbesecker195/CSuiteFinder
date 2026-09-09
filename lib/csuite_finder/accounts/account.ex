defmodule CsuiteFinder.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "accounts" do
    field :email, :string
    field :name, :string
    # Two pools, because credit has two lifetimes.
    #
    #   * `balance_micro` — bought. It never expires. Someone who paid for a
    #     thousand dollars of lookups still has them next year.
    #   * `granted_micro` — given. A seat's monthly allowance or the free trial,
    #     good until `granted_expires_at` and then gone.
    #
    # They are separate columns rather than one number with an expiry because a
    # single account holds both at once, and expiring the wrong dollars would
    # take money the customer paid for.
    field :balance_micro, :integer, default: 0
    field :granted_micro, :integer, default: 0
    field :granted_expires_at, :utc_datetime_usec
    field :trial_granted_at, :utc_datetime_usec
    field :status, :string, default: "active"
    # Which half of the business this account is in. See CsuiteFinder.Audience:
    # it decides which prices, which purchase path and which nav they see.
    field :audience, :string, default: "sales"

    has_many :api_keys, CsuiteFinder.Accounts.ApiKey

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :email,
      :name,
      :balance_micro,
      :granted_micro,
      :granted_expires_at,
      :trial_granted_at,
      :status,
      :audience
    ])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> update_change(:email, &String.downcase/1)
    |> validate_inclusion(:status, ~w(active suspended))
    |> validate_inclusion(:audience, CsuiteFinder.Audience.all())
    |> unique_constraint(:email)
  end
end
