defmodule CsuiteFinderWeb.Plugs.RequireFunds do
  @moduledoc """
  Refuse a lookup the caller cannot pay for, *before* it costs us anything
  upstream. Without this the first thing an empty account does is spend our
  money at a provider.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias CsuiteFinder.Billing

  def init(opts), do: opts

  def call(conn, _opts) do
    endpoint = endpoint_name(conn)

    case Billing.ensure_funds(conn.assigns[:account], endpoint) do
      :ok ->
        assign(conn, :endpoint_name, endpoint)

      {:error, :insufficient_credit, details} ->
        conn
        |> put_status(:payment_required)
        |> json(
          Map.merge(details, %{
            error: "insufficient_credit",
            message: message_for(details)
          })
        )
        |> halt()
    end
  end

  # An included endpoint refused for an empty balance is a different problem from
  # a metered one refused for being a token short, and the caller should be told
  # which — the fix for the first is buying anything at all.
  defp message_for(%{metered: false}) do
    "This endpoint is included, but needs a positive balance. " <>
      "Buy a bundle at POST /csuitefinder/billing/topup."
  end

  defp message_for(_details) do
    "Buy credit at POST /csuitefinder/billing/topup."
  end

  # "/csuitefinder/email/find" -> "email.find", which is how pricing and usage
  # rows are keyed.
  defp endpoint_name(conn) do
    conn.path_info
    |> Enum.reject(&(&1 == "csuitefinder"))
    |> Enum.join(".")
  end
end
