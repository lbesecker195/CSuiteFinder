defmodule CsuiteFinder.Cache do
  @moduledoc """
  Cache policy shared by every store.

  Nothing here talks to a provider. Two rules:

    * A row is *fresh* until it expires, and a negative result gets a shorter
      life than a positive one — a domain with no published pattern today may
      well have one next month, while a confirmed address rarely stops being
      that person's address.

    * **A known value is never discarded.** Expiry decides when we go and look
      again, not whether we still hold the answer. If that refresh comes back
      empty, the previous value is kept and served as known-but-stale rather
      than replaced by the nothing we just got. See `CsuiteFinder.Cache.Writer`.
  """

  @day 86_400

  @ttls %{
    pattern_found: 180 * @day,
    pattern_missing: 14 * @day,
    email_found: 90 * @day,
    email_missing: 30 * @day,
    verify_deliverable: 30 * @day,
    verify_undeliverable: 90 * @day,
    verify_risky: 7 * @day,
    enrichment_provider: 90 * @day,
    enrichment_inferred: 30 * @day,
    company: 60 * @day
  }

  # How long to wait before trying again after a refresh came back empty. Long
  # enough not to hammer a provider that has nothing, short enough that a value
  # which reappears upstream is picked up within the day.
  @retry_backoff @day

  @doc "Expiry timestamp for a cache class."
  @spec expires_at(atom()) :: DateTime.t()
  def expires_at(class) do
    DateTime.utc_now() |> DateTime.add(Map.fetch!(@ttls, class), :second)
  end

  @doc """
  When to retry after a refresh found nothing, having kept the old value.
  """
  @spec retry_at() :: DateTime.t()
  def retry_at, do: DateTime.add(DateTime.utc_now(), @retry_backoff, :second)

  @doc """
  Is this row's data stale — held from an earlier lookup that we have since
  failed to confirm?
  """
  @spec stale?(term()) :: boolean()
  def stale?(%{refresh_failures: n}) when is_integer(n) and n > 0, do: true
  def stale?(_), do: false

  @doc "Is this cached row still usable?"
  @spec fresh?(term()) :: boolean()
  def fresh?(nil), do: false
  def fresh?(%{expires_at: nil}), do: true

  def fresh?(%{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  @doc """
  Normalise a domain: strips a scheme, `www.`, any path, and the port, so
  `https://WWW.Stripe.com/careers` and `stripe.com` share one cache row.
  """
  @spec normalize_domain(String.t()) :: {:ok, String.t()} | {:error, :invalid_domain}
  def normalize_domain(domain) when is_binary(domain) do
    cleaned =
      domain
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r{^[a-z]+://}, "")
      |> String.split("/", parts: 2)
      |> hd()
      |> String.split("?", parts: 2)
      |> hd()
      |> String.split(":", parts: 2)
      |> hd()
      |> String.replace_prefix("www.", "")

    if Regex.match?(
         ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/,
         cleaned
       ) do
      {:ok, cleaned}
    else
      {:error, :invalid_domain}
    end
  end

  def normalize_domain(_), do: {:error, :invalid_domain}

  @doc "Validate and normalise an email address, returning it with its domain."
  @spec normalize_email(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_email}
  def normalize_email(email) when is_binary(email) do
    cleaned = email |> String.trim() |> String.downcase()

    with [local, domain] <- String.split(cleaned, "@"),
         true <- local != "" and String.length(local) <= 64,
         false <- String.contains?(local, " "),
         {:ok, domain} <- normalize_domain(domain) do
      {:ok, local <> "@" <> domain, domain}
    else
      _ -> {:error, :invalid_email}
    end
  end

  def normalize_email(_), do: {:error, :invalid_email}
end
