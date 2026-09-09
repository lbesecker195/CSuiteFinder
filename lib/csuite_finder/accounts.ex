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
  alias CsuiteFinder.Billing
  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.Repo

  @key_prefix "csf_live_"

  @doc "Create an account."
  @spec create_account(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account(attrs) do
    %Account{} |> Account.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Register a new account: create it, grant the free trial, and mint its first key.

  The whole thing is one transaction, so a failure part-way cannot leave an
  account that exists but has no key, or a key with no trial tokens.

  `trial_granted_at` is the guard against re-registering the same address for
  another free grant — the trial is per account, once.
  """
  @spec register(map()) ::
          {:ok, %{account: Account.t(), api_key: String.t(), credit_granted_micro: integer()}}
          | {:error, Ecto.Changeset.t()}
  def register(attrs) do
    grant = Pricing.trial_micro()

    Repo.transaction(fn ->
      with {:ok, account} <- create_account(attrs),
           {:ok, account} <- grant_trial(account, grant) do
        {:ok, plaintext, _key} = create_api_key(account, "initial key")
        %{account: account, api_key: plaintext, credit_granted_micro: grant}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp grant_trial(%Account{trial_granted_at: nil} = account, micro) do
    {:ok, account} = Billing.credit(account, micro)

    account
    |> Account.changeset(%{trial_granted_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp grant_trial(account, _micro), do: {:ok, account}

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
