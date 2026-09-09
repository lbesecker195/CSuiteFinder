defmodule CsuiteFinder.TregStub do
  @moduledoc """
  Stands in for treg in tests.

  Req calls this plug inline in the calling process, which for a Phoenix
  controller test is the test process — so a stub registered with `stub/1` is
  visible to the code under test without any global state, and tests stay async.
  """

  import Plug.Conn

  @doc """
  Register a responder: `fn endpoint_id, body -> {status, json, cost_micro} end`.
  """
  def stub(fun) when is_function(fun, 2), do: Process.put(__MODULE__, fun)

  @doc "Every treg call made in this test, newest last."
  def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

  @doc "How many upstream calls were made — the assertion that proves caching."
  def call_count, do: length(calls())

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: %{}, else: Jason.decode!(raw)
    endpoint = conn.path_info |> Enum.drop(1) |> Enum.join("/")

    record(endpoint, body, conn.query_params)

    {status, payload, cost} =
      case Process.get(__MODULE__) do
        nil -> {404, %{}, 0}
        fun -> fun.(endpoint, Map.merge(body, conn.query_params))
      end

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("x-treg-cost-micro", to_string(cost))
    |> put_resp_header("x-treg-call-id", "test-call-id")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp record(endpoint, body, query) do
    existing = Process.get({__MODULE__, :calls}, [])

    Process.put({__MODULE__, :calls}, [%{endpoint: endpoint, body: body, query: query} | existing])
  end

  @doc "A successful routed response in treg's envelope shape."
  def routed(output, opts \\ []) do
    %{
      "output" => output,
      "raw" => Keyword.get(opts, :raw, %{}),
      "_treg" => %{
        "served_by" => Keyword.get(opts, :served_by, "test.provider"),
        "outcome" => "hit",
        "tried" =>
          Keyword.get(opts, :tried, [
            %{
              "endpoint_id" => Keyword.get(opts, :served_by, "test.provider"),
              "outcome" => "hit",
              "charged_micro" => Keyword.get(opts, :cost, 0)
            }
          ])
      }
    }
  end
end
