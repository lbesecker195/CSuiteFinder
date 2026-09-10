defmodule CsuiteFinder.InferenceStub do
  @moduledoc """
  Stands in for the Anthropic API in tests.

  A test arms it with `stub/1` and the plug answers in-process, so no test
  reaches the network and none of them share state: the function is held in the
  calling process's own dictionary.
  """

  @key :inference_stub

  @doc """
  Answer the next request with `text`, or run `fun.(prompt)` for it.

  Also switches the fallback on for this test — with no API key configured
  `CsuiteFinder.Inference` refuses to make a request at all.
  """
  @spec stub(String.t() | (String.t() -> String.t())) :: :ok
  def stub(answer) do
    Application.put_env(
      :csuite_finder,
      CsuiteFinder.Inference,
      Application.get_env(:csuite_finder, CsuiteFinder.Inference, [])
      |> Keyword.put(:api_key, "test-key")
    )

    Process.put(@key, answer)
    :ok
  end

  @doc "Forget any armed answer. The fallback then behaves as if switched off."
  @spec reset() :: :ok
  def reset do
    Process.delete(@key)
    :ok
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    prompt = prompt_of(body)

    case Process.get(@key) do
      nil ->
        respond(conn, 400, %{"error" => %{"message" => "no stub armed"}})

      fun when is_function(fun, 1) ->
        respond(conn, 200, message(fun.(prompt)))

      text when is_binary(text) ->
        respond(conn, 200, message(text))
    end
  end

  defp prompt_of(body) do
    case Jason.decode(body) do
      {:ok, %{"messages" => [%{"content" => content} | _]}} -> content
      _ -> ""
    end
  end

  defp message(text) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"input_tokens" => 60, "output_tokens" => 6}
    }
  end

  defp respond(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end
end
