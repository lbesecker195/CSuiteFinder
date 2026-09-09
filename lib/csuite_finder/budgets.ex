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
    company_enrich: 0.005,
    # A page of ten people. The provider charges ceil(limit/10) credits, so a
    # 50-row sweep needs headroom for five.
    company_people: 0.05,
    # The cheap provider wants a name and a domain ($0.0048). The one that takes
    # a bare email is $0.0445 — above this ceiling on purpose, so a careless
    # email-only request is refused rather than costing ten times as much.
    phone_find: 0.04,
    # The email path is allowed more than the name path because it costs two
    # calls, not one: an enrichment to learn the name, then the find itself
    # (~$0.0097 together). Deliberately subsidised — the result is an email and
    # a phone attributed to the same person, which is what makes /phone/who work
    # later. No provider sells a bare-email phone lookup under $0.0445, so this
    # ceiling buys the two-step route rather than a one-step one.
    phone_find_from_email: 0.02,
    phone_verify: 0.01
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
