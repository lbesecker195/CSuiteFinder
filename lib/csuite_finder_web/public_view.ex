defmodule CsuiteFinderWeb.PublicView do
  @moduledoc """
  What a customer is allowed to see.

  The contexts build rich maps — which provider served, what it cost, whether
  the cache answered, how the address was derived. All of that is ours: it is
  operational detail, it names the upstreams we buy from, and it prices our
  margin for anyone who reads a response. None of it belongs in the API.

  This module is the boundary. It works by **whitelist, not blacklist**, so the
  default for a newly added internal field is to stay internal. Adding one to a
  context cannot leak it by accident; it has to be listed here on purpose.

  Nothing is removed from the database or the admin dashboard — billing depends
  on knowing whether a result was provider-verified or inferred, and the cost
  model depends on knowing who served it. Only the public projection changes.
  """

  @email_find ~w(email full_name domain found confidence verification_status
                 last_verified_at)a

  @deliverable ~w(email deliverable status sub_status score catch_all disposable
                  role_account free_provider mx_found smtp_check checked_at)a

  # `position_inferred` is listed deliberately: a guessed job title and a
  # provider's stated one look identical in the response otherwise, and the
  # caller is the one about to address someone by it.
  @enrich ~w(email found full_name first_name last_name position position_inferred
             seniority department company_name linkedin_url twitter location phone
             confidence last_verified_at)a

  # `pattern` is the answer this endpoint exists to give, so it stays. What goes
  # is `source`, which named the upstream that supplied it.
  @pattern ~w(domain found pattern pattern_provider_notation example confidence
              alternatives queried_email last_verified_at)a

  @who ~w(email found full_name first_name last_name position position_inferred
          company_name linkedin_url confidence)a

  @company_find ~w(queried_email domain found name legal_name website
                   linkedin_url logo_url last_verified_at note)a

  # A person in a /company/people result. The list wrapper is built by the
  # controller; this is the per-row shape.
  @person ~w(email full_name first_name last_name position department seniority
             linkedin_url twitter kind confidence)a

  # The same person, plus the number that cost a lookup of its own.
  @person_with_phone @person ++ ~w(phone phone_line_type)a

  # One company in a search result: thinner than a full profile, because a
  # search row is what the provider gave us and not a profile lookup.
  @company_row ~w(domain name industry employee_count employee_range country city
                  website linkedin_url description tech_stack)a

  @company_info ~w(domain found name legal_name description industry
                   employee_count employee_range founded_year revenue_range
                   country city website linkedin_url logo_url tech_stack
                   last_verified_at note)a

  @doc "Project a context result onto its public shape."
  @spec render(atom(), map()) :: map()
  def render(:email_find, result), do: take(result, @email_find)
  def render(:deliverable, result), do: take(result, @deliverable)
  def render(:enrich, result), do: take(result, @enrich)
  def render(:pattern, result), do: take(result, @pattern)
  def render(:who, result), do: take(result, @who)
  def render(:company_find, result), do: take(result, @company_find)
  def render(:company_info, result), do: take(result, @company_info)
  def render(:company_row, result), do: take(result, @company_row)
  def render(:person, result), do: take(result, @person)
  def render(:person_with_phone, result), do: take(result, @person_with_phone)

  @doc "The field list for a view, for tests and documentation."
  @spec fields(atom()) :: [atom()]
  def fields(:email_find), do: @email_find
  def fields(:deliverable), do: @deliverable
  def fields(:enrich), do: @enrich
  def fields(:pattern), do: @pattern
  def fields(:who), do: @who
  def fields(:company_find), do: @company_find
  def fields(:company_info), do: @company_info
  def fields(:company_row), do: @company_row
  def fields(:person), do: @person
  def fields(:person_with_phone), do: @person_with_phone

  # Keys absent from the result are simply absent from the response, rather
  # than rendered as nulls that imply a field we do not have.
  defp take(result, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(result, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
