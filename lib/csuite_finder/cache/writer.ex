defmodule CsuiteFinder.Cache.Writer do
  @moduledoc """
  Writes a cache row without ever losing a value we already had.

  The failure this exists to prevent: we hold a good answer, its TTL lapses, we
  go back to the provider, and the provider is down or has since dropped the
  record. A plain upsert would replace a correct answer with an empty one and
  the customer would get nothing — for a question we *had* answered. Worse, the
  emptiness would then be cached in its own right.

  So a refresh that comes back empty does not write. It leaves the known value
  in place, counts the failure, and pushes the retry clock out by a day. The row
  is then served as stale, with `last_found_at` saying how old the answer is, so
  a caller can decide for themselves whether it is still good enough.
  """

  alias CsuiteFinder.Cache
  alias CsuiteFinder.Repo

  @doc """
  Insert or update a cache row.

  `known?` says whether this write carries real data. It defaults to the
  `:found` flag, which every cache schema but `email_verifications` uses — that
  one records a verdict instead, and passes `known?` explicitly.
  """
  @spec put(module(), [atom()], map(), keyword()) :: struct()
  def put(schema, conflict_target, attrs, opts \\ []) do
    known? = Keyword.get(opts, :known?, Map.get(attrs, :found) == true)
    existing = load_existing(schema, conflict_target, attrs)

    cond do
      known? ->
        upsert(schema, conflict_target, Map.put(attrs, :last_found_at, DateTime.utc_now()))

      holds_value?(existing) ->
        preserve(schema, existing)

      true ->
        upsert(schema, conflict_target, attrs)
    end
  end

  # A row that has ever held real data is worth more than a fresh negative.
  defp holds_value?(%{last_found_at: %DateTime{}}), do: true
  defp holds_value?(_), do: false

  defp preserve(schema, existing) do
    existing
    |> schema.changeset(%{
      expires_at: Cache.retry_at(),
      refresh_failures: (existing.refresh_failures || 0) + 1
    })
    |> Repo.update!()
  end

  defp upsert(schema, conflict_target, attrs) do
    # A confirmed value resets the staleness counter.
    attrs = Map.put_new(attrs, :refresh_failures, 0)

    schema
    |> struct()
    |> schema.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: conflict_target,
      returning: true
    )
  end

  defp load_existing(schema, conflict_target, attrs) do
    clauses =
      Enum.map(conflict_target, fn field ->
        {field, normalize(field, Map.get(attrs, field))}
      end)

    if Enum.any?(clauses, fn {_field, value} -> is_nil(value) end) do
      nil
    else
      Repo.get_by(schema, clauses)
    end
  end

  # The schemas downcase these in their changesets, so the lookup has to match.
  defp normalize(field, value) when field in [:domain, :email] and is_binary(value),
    do: String.downcase(value)

  defp normalize(_field, value), do: value
end
