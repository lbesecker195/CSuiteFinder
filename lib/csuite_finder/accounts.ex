defmodule CsuiteFinder.Accounts do
  @moduledoc """
  Customer accounts and their API keys.

  Keys are stored only as SHA-256 hashes. The plaintext is returned once, at
  creation, and is unrecoverable afterwards — a leaked database gives an attacker
  nothing they can present as a key.

  Registering grants the free trial once per account; see `register/1`.

  A lost key cannot be recovered — only a hash is stored. What an account holder
  can do is mint a spare while they still have a working one, which is what
  `create_api_key/2` and `list_api_keys/1` are for.
  """

  import Ecto.Query

  alias CsuiteFinder.Accounts.{Account, ApiKey}
  alias CsuiteFinder.Audience
  alias CsuiteFinder.Repo

  @key_prefix "csf_live_"

  @doc "Create an account."
  @spec create_account(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account(attrs) do
    # Only these three are settable at creation; a balance or a status arriving
    # with a signup would be someone else's idea, not ours. The audience comes
    # from a browser or an API caller, so it is normalised rather than trusted —
    # an unrecognised value becomes the safe default instead of failing a signup
    # over a typo.
    %Account{}
    |> Account.changeset(%{
      email: field(attrs, :email),
      name: field(attrs, :name),
      audience: Audience.cast(field(attrs, :audience))
    })
    |> Repo.insert()
  end

  # Accepts either key style: the API hands us string keys, everything internal
  # uses atoms.
  defp field(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  @doc "Move an account to the other half of the business."
  @spec set_audience(Account.t(), String.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def set_audience(%Account{} = account, audience) do
    account |> Account.changeset(%{audience: Audience.cast(audience)}) |> Repo.update()
  end

  @doc """
  Register a new account: create it, grant the free trial, and mint its first key.

  The whole thing is one transaction, so a failure part-way cannot leave an
  account that exists but has no key, or a key with no trial tokens.

  `trial_granted_at` is the guard against re-registering the same address for
  another free grant — the trial is per account, once.

  Registering grants no credit, on either side of the business. There is no free
  tier: a trial is bought once, for $#{CsuiteFinder.Billing.Pricing.trial_usd()},
  and expires with the month — see
  `CsuiteFinder.Billing.PayPal.create_trial_order/2`. A new account therefore
  starts at zero and is refused every lookup until it pays, which is the
  intended shape rather than an oversight.

  `trial_granted_at` is still the guard that makes the trial once-per-account;
  it is now stamped when the payment captures rather than at registration.
  """
  @spec register(map()) ::
          {:ok, %{account: Account.t(), api_key: String.t(), credit_granted_micro: integer()}}
          | {:error, Ecto.Changeset.t()}
  def register(attrs) do
    Repo.transaction(fn ->
      case create_account(attrs) do
        {:ok, account} ->
          {:ok, plaintext, _key} = create_api_key(account, "initial key")
          %{account: account, api_key: plaintext, credit_granted_micro: 0}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @spec get_account(integer()) :: Account.t() | nil
  def get_account(id), do: Repo.get(Account, id)

  @doc """
  Mint an API key. Returns the plaintext exactly once — store it or lose it.
  """
  @spec create_api_key(Account.t(), String.t() | nil) :: {:ok, String.t(), ApiKey.t()}
  def create_api_key(%Account{} = account, label \\ nil) do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    plaintext = @key_prefix <> secret

    {:ok, key} =
      %ApiKey{}
      |> ApiKey.changeset(%{
        account_id: account.id,
        key_hash: hash(plaintext),
        prefix: String.slice(plaintext, 0, 16),
        label: label
      })
      |> Repo.insert()

    {:ok, plaintext, key}
  end

  @doc """
  Resolve a presented key to its account.

  The lookup is by hash, so a timing side-channel on the comparison cannot leak
  the key, and revoked or suspended holders are rejected before any work starts.
  """
  @spec authenticate(String.t()) ::
          {:ok, Account.t(), ApiKey.t()} | {:error, :invalid_key | :suspended}
  def authenticate(presented) when is_binary(presented) do
    hashed = hash(presented)

    query =
      from k in ApiKey,
        where: k.key_hash == ^hashed and is_nil(k.revoked_at),
        preload: [:account]

    case Repo.one(query) do
      nil ->
        {:error, :invalid_key}

      %ApiKey{account: %Account{status: "active"} = account} = key ->
        # Fire-and-forget touch; a failed timestamp update must not fail the call.
        Repo.update_all(from(k in ApiKey, where: k.id == ^key.id),
          set: [last_used_at: DateTime.utc_now()]
        )

        {:ok, account, key}

      %ApiKey{} ->
        {:error, :suspended}
    end
  end

  def authenticate(_), do: {:error, :invalid_key}

  @spec revoke_api_key(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def revoke_api_key(%ApiKey{} = key) do
    key |> ApiKey.changeset(%{revoked_at: DateTime.utc_now()}) |> Repo.update()
  end

  # ---------------------------------------------------------- key management

  @doc "Every key ever issued for an account, newest first."
  @spec list_api_keys(Account.t()) :: [ApiKey.t()]
  def list_api_keys(%Account{id: id}) do
    Repo.all(from k in ApiKey, where: k.account_id == ^id, order_by: [desc: k.id])
  end

  @doc "One of this account's keys, or nil. Scoped so an id cannot reach another account's key."
  @spec get_api_key(Account.t(), integer() | String.t()) :: ApiKey.t() | nil
  def get_api_key(%Account{id: account_id}, id) do
    case Integer.parse(to_string(id)) do
      {key_id, _} ->
        Repo.one(from k in ApiKey, where: k.id == ^key_id and k.account_id == ^account_id)

      :error ->
        nil
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
