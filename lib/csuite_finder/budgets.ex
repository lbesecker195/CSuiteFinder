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
    # A page of company rows for an account list. Most providers here bill per
    # row at a fifth of a cent, so this covers a full 50-row page with room for
    # the waterfall to try a dearer one — and stops a single call wandering into
    # the $0.38 provider at the bottom of the route.
    company_search: 0.06,
    # A page of ten people. The provider charges ceil(limit/10) credits, so a
    # 50-row sweep needs headroom for five.
    company_people: 0.05,
    # The cheap provider wants a name and a domain ($0.0048). The one taking a
    # bare email is $0.0445 — reachable on the email path below, but never on
    # this one, so a name-and-domain request cannot silently cost ten times what
    # it should.
    phone_find: 0.04,
    # $0.06 for an email-input lookup: the $0.04 above plus $0.02 of subsidy.
    # It buys two routes, tried cheap-first — resolve the name and ask by name
    # (~$0.0097), and if that yields nothing, go direct with the email at
    # $0.0445. Worth the subsidy because the result is an email and a phone
    # attributed to the same person, which is what makes /phone/who answerable.
    phone_find_from_email: 0.06,
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
