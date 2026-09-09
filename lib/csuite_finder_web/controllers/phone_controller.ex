defmodule CsuiteFinderWeb.PhoneController do
  @moduledoc """
  Phone numbers: find one, validate one, and look one up backwards.

  The reverse route is answered from our own rows and costs nothing. No provider
  in the catalog turns a number back into a person, so what makes it work is
  that every number this service finds is kept against whoever it belongs to.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.{Billing, Phones}
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
  POST/GET /csuitefinder/phone/who — whose number is this.

  Answered entirely from numbers this service has already found, so it is free
  and it gets better with use. An unknown number is `found: false` rather than
  a paid lookup, because there is nothing to buy: no provider offers reverse
  phone lookup.
  """
  def who(conn, params) do
    with {:ok, number} <- require_param(params, "phone") do
      case Phones.owner(number) do
        {:ok, phone} ->
          meter(conn, true, CsuiteFinder.Lookup.hit(), %{phone: number})
          json(conn, Phones.present(phone, CsuiteFinder.Lookup.hit()))

        {:error, :unknown} ->
          meter(conn, false, CsuiteFinder.Lookup.hit(), %{phone: number})

          json(conn, %{
            phone: number,
            found: false,
            message: "We have not seen that number. It is only known once we have found it."
          })

        error ->
          error
      end
    end
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
