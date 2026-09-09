defmodule CsuiteFinder.Budgets do
  @moduledoc """
  Per-endpoint spend ceilings, in USD, for a single upstream lookup.

  These are passed to treg as `X-Treg-Route-Max-Cost`, so the ceiling is enforced
  on treg's side before a provider is called. A route that would cost more comes
  back as an unbilled miss rather than an over-budget charge.
  """

  @budgets %{
    email_find: 0.02,
    email_verify: 0.002,
    person_enrich: 0.005,
    email_pattern: 0.01,
    company_enrich: 0.005
  }

  @doc "Ceiling in USD for a lookup kind."
  @spec usd(atom()) :: float()
  def usd(kind), do: Map.fetch!(@budgets, kind)

  @doc "Ceiling in micro-USD."
  @spec micro(atom()) :: integer()
  def micro(kind), do: round(usd(kind) * 1_000_000)

  @doc "All ceilings, for the ops/pricing endpoint."
  @spec all() :: map()
  def all, do: @budgets
end
