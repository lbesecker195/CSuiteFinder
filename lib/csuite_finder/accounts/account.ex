defmodule CsuiteFinder.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "accounts" do
    field :email, :string
    field :name, :string
    field :token_balance, :integer, default: 0
    field :trial_granted_at, :utc_datetime_usec
    field :status, :string, default: "active"

    has_many :api_keys, CsuiteFinder.Accounts.ApiKey

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:email, :name, :token_balance, :trial_granted_at, :status])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> update_change(:email, &String.downcase/1)
    |> validate_inclusion(:status, ~w(active suspended))
    |> unique_constraint(:email)
  end
end
