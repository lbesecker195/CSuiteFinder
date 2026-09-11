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
  @session_prefix "csf_sess_"

  # NIST's floor for a user-chosen secret, with no composition rules — a rule
  # that forces a symbol produces "Password1!" and nothing else. Length is what
  # helps, so longer is better, but eight is where we refuse.
  @min_password 8

  # Brute force is the entire risk of putting a password on a system that had
  # none. Five wrong guesses buys a quarter of an hour of silence.
  @max_attempts 5
  @lockout_seconds 15 * 60

  # A browser session, not an API credential. It expires on its own, so a
  # laptop left in a hotel stops being a way in eventually even if nobody
  # thinks to revoke it.
  @session_days 30

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
          # A password is optional here. Someone who sets one can sign in
          # without keeping the key to hand; someone who does not carries on
          # exactly as before.
          account =
            case field(attrs, :password) do
              nil -> account
              password -> with({:ok, updated} <- set_password(account, password), do: updated)
            end

          {:ok, plaintext, _key} = create_api_key(account, "initial key")
          %{account: account, api_key: plaintext, credit_granted_micro: 0}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Give an account a password, or change the one it has.

  A password is how a person reaches the account page. The API itself is
  key-authenticated and a password has no part in it, so an account created by
  an agent through `POST /register` needs one only if a human will ever sign in.

  There is no reset flow, because there is no mail server to send one through.
  An operator resets it with `CsuiteFinder.Release.set_password/2`; the page
  says as much before it asks anyone to depend on one.
  """
  @spec set_password(Account.t(), String.t()) :: {:ok, Account.t()} | {:error, atom()}
  def set_password(%Account{} = account, password) when is_binary(password) do
    if String.length(String.trim(password)) < @min_password do
      {:error, :password_too_short}
    else
      account
      |> Account.changeset(%{
        password_hash: Bcrypt.hash_pwd_salt(password),
        failed_logins: 0,
        locked_until: nil
      })
      |> Repo.update()
      |> case do
        {:ok, account} -> {:ok, account}
        {:error, _changeset} -> {:error, :invalid}
      end
    end
  end

  def set_password(_account, _password), do: {:error, :password_too_short}

  @doc "The shortest password we will accept."
  @spec min_password_length() :: pos_integer()
  def min_password_length, do: @min_password

  @doc """
  Sign in with an email address and a password.

  Returns a **session token**, not the account's API key: we hold only a hash of
  that key and could not return it if we wanted to, and minting something
  separate means a browser session can expire without touching the credential a
  script depends on.

  Every failure answers `:invalid_login`, whether the address is unknown or the
  password is wrong, and an unknown address still pays the cost of a hash — an
  attacker must not be able to enumerate customers by timing the reply.
  """
  @spec login(String.t(), String.t()) ::
          {:ok, Account.t(), String.t(), DateTime.t()}
          | {:error, :invalid_login | :locked | :suspended}
  def login(email, password) when is_binary(email) and is_binary(password) do
    account = Repo.get_by(Account, email: String.downcase(String.trim(email)))

    cond do
      is_nil(account) or is_nil(account.password_hash) ->
        # Same work, same answer, whether or not the account exists.
        Bcrypt.no_user_verify()
        {:error, :invalid_login}

      locked?(account) ->
        {:error, :locked}

      account.status != "active" ->
        {:error, :suspended}

      Bcrypt.verify_pass(password, account.password_hash) ->
        {:ok, account} = clear_failures(account)
        {token, expires_at} = start_session(account)
        {:ok, account, token, expires_at}

      true ->
        record_failure(account)
        {:error, :invalid_login}
    end
  end

  def login(_email, _password) do
    Bcrypt.no_user_verify()
    {:error, :invalid_login}
  end

  @doc "Mint a browser session token for an account. Returns the token and its expiry."
  @spec start_session(Account.t()) :: {String.t(), DateTime.t()}
  def start_session(%Account{} = account) do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    token = @session_prefix <> secret
    expires_at = DateTime.add(DateTime.utc_now(), @session_days * 86_400, :second)

    {:ok, _key} =
      %ApiKey{}
      |> ApiKey.changeset(%{
        account_id: account.id,
        key_hash: hash(token),
        prefix: String.slice(token, 0, 16),
        label: "browser session",
        kind: "session",
        expires_at: expires_at
      })
      |> Repo.insert()

    {token, expires_at}
  end

  @doc "End a browser session."
  @spec end_session(ApiKey.t()) :: :ok
  def end_session(%ApiKey{} = key) do
    revoke_api_key(key)
    :ok
  end

  defp locked?(%Account{locked_until: nil}), do: false

  defp locked?(%Account{locked_until: until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt

  defp clear_failures(%Account{failed_logins: 0, locked_until: nil} = account),
    do: {:ok, account}

  defp clear_failures(account) do
    account |> Account.changeset(%{failed_logins: 0, locked_until: nil}) |> Repo.update()
  end

  defp record_failure(account) do
    failures = (account.failed_logins || 0) + 1

    account
    |> Account.changeset(%{
      failed_logins: failures,
      locked_until:
        if(failures >= @max_attempts,
          do: DateTime.add(DateTime.utc_now(), @lockout_seconds, :second)
        )
    })
    |> Repo.update()
  end

  @doc """
  An account by its address, or nil.

  Downcased and trimmed on the way in. The column is citext so the database
  would match anyway, but a stray space would not, and the addresses reaching
  this come from a payment processor rather than from our own form.
  """
  @spec get_account_by_email(String.t() | nil) :: Account.t() | nil
  def get_account_by_email(email) when is_binary(email) do
    Repo.get_by(Account, email: email |> String.trim() |> String.downcase())
  end

  def get_account_by_email(_), do: nil

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

    now = DateTime.utc_now()

    query =
      from k in ApiKey,
        where:
          k.key_hash == ^hashed and is_nil(k.revoked_at) and
            (is_nil(k.expires_at) or k.expires_at > ^now),
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
