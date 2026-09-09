defmodule CsuiteFinderWeb.PhoneController do
  @moduledoc """
  Phone numbers: find one, validate one, and look one up backwards.

  The reverse route is answered from our own rows and costs nothing. No provider
  in the catalog turns a number back into a person, so what makes it work is
  that every number this service finds is kept against whoever it belongs to.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.{Billing, Companies, Lookup, People, Phones}
  alias CsuiteFinderWeb.Plugs.Timing

  action_fallback CsuiteFinderWeb.FallbackController

  @doc "POST/GET /csuitefinder/phone/find"
  def find(conn, params) do
    identity =
      %{}
      |> put_if(params, "full_name")
      |> put_if(params, "domain")
      |> put_if(params, "email")
      |> put_if(params, "linkedin_url")

    with {:ok, phone, lookup} <- Phones.find(identity, refresh: truthy(params["refresh"])) do
      meter(conn, phone.found, lookup, identity)
      json(conn, Phones.present(phone, lookup))
    end
  end

  @doc """
  POST/GET /csuitefinder/phone/valid — is this number real, and what kind of line.
  """
  def valid(conn, params) do
    with {:ok, number} <- require_param(params, "phone"),
         {:ok, phone, lookup} <-
           Phones.validate(number,
             country_code: params["country_code"],
             refresh: truthy(params["refresh"])
           ) do
      meter(conn, phone.valid != nil, lookup, %{phone: number})
      json(conn, Phones.present(phone, lookup))
    end
  end

  @doc """
  POST/GET /csuitefinder/phone/name — whose number is this.

  The phone counterpart of `/email/name`. Every phone route here is answered
  from numbers this service has already found, so all of them are free and all
  of them get better with use: no provider sells reverse phone lookup, which is
  why an unknown number is `found: false` rather than a paid attempt.
  """
  def name(conn, params) do
    with {:ok, number} <- require_param(params, "phone") do
      case Phones.owner(number) do
        {:ok, phone} ->
          meter(conn, true, Lookup.hit(), %{phone: number})

          json(conn, %{
            phone: phone.e164 || phone.phone,
            found: true,
            full_name: phone.full_name,
            first_name: phone.first_name,
            last_name: phone.last_name,
            position: phone.position,
            email: phone.email,
            company_name: phone.domain
          })

        {:error, :unknown} ->
          unknown(conn, number)

        error ->
          error
      end
    end
  end

  @doc """
  POST/GET /csuitefinder/phone/enrich — the person behind a number.

  The phone counterpart of `/email/enrich`. Resolves the number to the address
  we attributed it to and enriches that; a number we hold with no address still
  answers with what the row itself knows.
  """
  def enrich(conn, params) do
    with {:ok, number} <- require_param(params, "phone") do
      case Phones.owner(number) do
        {:ok, %{email: email} = phone} when is_binary(email) ->
          case People.enrich(email) do
            {:ok, row, lookup} ->
              meter(conn, row.found, lookup, %{phone: number})
              json(conn, Map.put(People.present(row, lookup), :phone, phone.e164 || phone.phone))

            error ->
              error
          end

        {:ok, phone} ->
          meter(conn, true, Lookup.hit(), %{phone: number})

          json(conn, %{
            phone: phone.e164 || phone.phone,
            found: true,
            full_name: phone.full_name,
            first_name: phone.first_name,
            last_name: phone.last_name,
            position: phone.position,
            company_name: phone.domain,
            note: "We know whose number this is but hold no email address for them."
          })

        {:error, :unknown} ->
          unknown(conn, number)

        error ->
          error
      end
    end
  end

  @doc """
  POST/GET /csuitefinder/phone/company — the company behind a number.

  The phone counterpart of `/company/find`.
  """
  def company(conn, params) do
    with {:ok, number} <- require_param(params, "phone") do
      case Phones.owner(number) do
        {:ok, %{domain: domain} = phone} when is_binary(domain) ->
          case Companies.info(domain) do
            {:ok, row, lookup} ->
              meter(conn, row.found, lookup, %{phone: number})

              json(
                conn
                |> Plug.Conn.assign(:phone, phone),
                Map.put(
                  Companies.present_identity(row, lookup),
                  :phone,
                  phone.e164 || phone.phone
                )
              )

            error ->
              error
          end

        {:ok, _phone} ->
          meter(conn, false, Lookup.hit(), %{phone: number})

          json(conn, %{
            phone: number,
            found: false,
            message: "We know that number but not which company it belongs to."
          })

        {:error, :unknown} ->
          unknown(conn, number)

        error ->
          error
      end
    end
  end

  # There is nothing to buy here — no provider reverses a phone number — so an
  # unseen number is answered honestly rather than with a paid guess.
  defp unknown(conn, number) do
    meter(conn, false, Lookup.hit(), %{phone: number})

    json(conn, %{
      phone: number,
      found: false,
      message:
        "We have not seen that number. Numbers become known once found through /phone/find."
    })
  end

  defp meter(conn, found?, lookup, request) do
    Billing.settle(%{
      account: conn.assigns[:account],
      api_key: conn.assigns[:api_key],
      endpoint: conn.assigns[:endpoint_name],
      found: found?,
      cached: lookup.cached,
      provider_cost_micro: lookup.spent_micro,
      duration_ms: Timing.elapsed_ms(conn),
      request: request
    })
  end

  defp put_if(acc, params, key) do
    case params[key] do
      value when is_binary(value) and value != "" ->
        Map.put(acc, String.to_atom(key), String.trim(value))

      _ ->
        acc
    end
  end

  defp require_param(params, key) do
    case params[key] do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, :missing_params, [key]}, else: {:ok, trimmed}

      _ ->
        {:error, :missing_params, [key]}
    end
  end

  defp truthy(v), do: v in [true, "true", "1", 1]
end
