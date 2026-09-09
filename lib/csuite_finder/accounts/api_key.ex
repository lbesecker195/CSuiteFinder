defmodule CsuiteFinder.Accounts.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "api_keys" do
    field :key_hash, :string
    field :prefix, :string
    field :label, :string
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :account, CsuiteFinder.Accounts.Account

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:account_id, :key_hash, :prefix, :label, :revoked_at, :last_used_at])
    |> validate_required([:account_id, :key_hash, :prefix])
    |> unique_constraint(:key_hash)
  end
end
