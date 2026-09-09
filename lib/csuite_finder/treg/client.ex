defmodule CsuiteFinder.Treg.Client do
  @moduledoc """
  Thin client over the treg proxy.

  Two things matter beyond the payload. First, every call carries an explicit
  `X-Treg-Route-Max-Cost` ceiling — the per-endpoint budgets are enforced by
  treg itself, so a routing change upstream can never quietly spend more than we
  budgeted. Second, we keep the `_treg.tried` waterfall off every response and
  hand it to the cost model, which is how we learn which providers actually hit.
  """

  require Logger

  @type meta :: %{
          cost_micro: non_neg_integer(),
          call_id: String.t() | nil,
          served_by: String.t() | nil,
          tried: [map()]
        }

  @doc """
  Call a treg endpoint by id.

  Options:
    * `:method`   — `:get` or `:post` (default `:post`)
    * `:body`     — map, sent as JSON for POST
    * `:query`    — keyword/map for GET
    * `:max_cost` — hard ceiling in USD for this call
    * `:idempotency_key` — replay a lost answer without paying twice
  """
  @spec call(String.t(), keyword()) ::
          {:ok, map(), meta()} | {:miss, meta()} | {:error, term(), meta()}
  def call(endpoint_id, opts \\ []) do
    method = Keyword.get(opts, :method, :post)
    max_cost = Keyword.fetch!(opts, :max_cost)

    url = base_url() <> "/call/" <> endpoint_id

    req_opts =
      [
        method: method,
        url: url,
        headers: headers(max_cost, opts),
        receive_timeout: Keyword.get(opts, :timeout, 30_000),
        retry: :transient,
        max_retries: 2
      ]
      |> put_payload(method, opts)
      |> maybe_stub()

    started = System.monotonic_time(:millisecond)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status} = resp} ->
        latency = System.monotonic_time(:millisecond) - started
        handle(status, resp, latency)

      {:error, reason} ->
        Logger.warning("treg #{endpoint_id} transport failure: #{inspect(reason)}")
        {:error, {:transport, reason}, empty_meta()}
    end
  end

  # Tests point this at a Plug instead of the network. Nothing else changes, so
  # the code under test is the same code that runs in production.
  defp maybe_stub(req_opts) do
    case config()[:plug] do
      nil -> req_opts
      plug -> Keyword.merge(req_opts, plug: plug, retry: false)
    end
  end

  defp put_payload(req_opts, :get, opts) do
    Keyword.put(req_opts, :params, Keyword.get(opts, :query, []))
  end

  defp put_payload(req_opts, _post, opts) do
    Keyword.put(req_opts, :json, Keyword.get(opts, :body, %{}))
  end

  defp handle(status, resp, latency) when status in 200..299 do
    body = resp.body
    meta = meta_from(resp, body, latency)

    case body do
      %{"output" => nil} -> {:miss, meta}
      %{"output" => output} when output == %{} -> {:miss, meta}
      %{} = map -> {:ok, map, meta}
      other -> {:ok, %{"output" => other}, meta}
    end
  end

  # A 402 is either an empty balance or our own ceiling refusing the call. The
  # second is not an error worth alarming on — it means the answer was priced
  # above what this endpoint is allowed to spend.
  defp handle(402, resp, latency) do
    meta = meta_from(resp, resp.body, latency)

    case resp.body do
      %{"error" => "route_max_cost"} -> {:miss, %{meta | cost_micro: 0}}
      _ -> {:error, :insufficient_balance, meta}
    end
  end

  defp handle(404, resp, latency), do: {:miss, meta_from(resp, resp.body, latency)}

  defp handle(status, resp, latency) do
    meta = meta_from(resp, resp.body, latency)
    Logger.warning("treg returned #{status}: #{inspect(resp.body)}")
    {:error, {:http, status, resp.body}, meta}
  end

  defp meta_from(resp, body, latency) do
    treg = if is_map(body), do: Map.get(body, "_treg", %{}), else: %{}

    %{
      cost_micro: header_int(resp, "x-treg-cost-micro") || Map.get(treg, "charged_micro", 0),
      call_id: header(resp, "x-treg-call-id"),
      served_by: Map.get(treg, "served_by") || header(resp, "x-treg-served-by"),
      tried: Map.get(treg, "tried", []),
      latency_ms: latency
    }
  end

  defp empty_meta,
    do: %{cost_micro: 0, call_id: nil, served_by: nil, tried: [], latency_ms: 0}

  defp header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp header_int(resp, name) do
    with value when is_binary(value) <- header(resp, name),
         {int, _} <- Integer.parse(value) do
      int
    else
      _ -> nil
    end
  end

  defp headers(max_cost, opts) do
    base = [
      {"x-treg-token", token()},
      {"x-treg-route-max-cost", to_string(max_cost)},
      {"content-type", "application/json"}
    ]

    base
    |> maybe_put("x-treg-org", org())
    |> maybe_put("idempotency-key", Keyword.get(opts, :idempotency_key))
    |> maybe_put("x-treg-route-prefer", Keyword.get(opts, :prefer))
  end

  defp maybe_put(headers, _name, nil), do: headers
  defp maybe_put(headers, _name, ""), do: headers
  defp maybe_put(headers, name, value), do: [{name, value} | headers]

  @doc "Is a treg token configured in this environment?"
  @spec configured?() :: boolean()
  def configured? do
    case token() do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  defp config, do: Application.get_env(:csuite_finder, __MODULE__, [])
  defp base_url, do: config()[:base_url] || "https://treg.to"
  defp token, do: config()[:token] || System.get_env("TREG_TOKEN") || ""
  defp org, do: config()[:org] || System.get_env("TREG_ORG")
end
