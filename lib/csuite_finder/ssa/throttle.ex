defmodule CsuiteFinder.Ssa.Throttle do
  @moduledoc """
  Batches usage pings, because their documentation asks us to.

  > Batch what you can and send at most one ping every 10 seconds per session
  > for automated activity. There is no rate-limit response to back off from —
  > the endpoint always returns 204 — so self-limit.

  The first version of this integration sent one ping per billable request,
  which on a customer sweeping four hundred rows is four hundred pings in a
  minute. That is not what they asked for, and there is no error to notice it
  by: the endpoint returns 204 whatever you do, so a service that behaves badly
  here never finds out.

  So calls accumulate in this process and one ping goes out every ten seconds
  carrying the totals. The dashboard gets the same picture — lookups, how many
  the cache answered, how many found something — at a fortieth of the traffic.

  Nothing is sent when nothing happened: an idle service should be silent, not
  reporting zero every ten seconds forever.
  """

  use GenServer

  alias CsuiteFinder.Ssa

  @every :timer.seconds(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Note one billable request. Returns immediately.

  A cast rather than a call: a customer's lookup must never wait on analytics
  bookkeeping, and must never fail because this process is busy or missing.

  Counting happens whether or not analytics are switched on; `Ssa.ping/2` is
  what decides whether anything leaves the machine. Keeping those separate means
  the batching is testable without a uid, and that switching analytics on is a
  configuration change rather than a different code path.
  """
  @spec record(String.t(), boolean(), boolean(), pos_integer()) :: :ok
  def record(endpoint, found?, cached?, units \\ 1) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:record, endpoint, found?, cached?, units})
    end

    :ok
  end

  @doc "Flush now and return what was sent. For tests and for ops."
  @spec flush() :: map()
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, empty()}
  end

  @impl true
  def handle_cast({:record, endpoint, found?, cached?, units}, state) do
    {:noreply,
     %{
       state
       | calls: state.calls + 1,
         units: state.units + units,
         found: state.found + if(found?, do: 1, else: 0),
         cached: state.cached + if(cached?, do: 1, else: 0),
         endpoints: Map.update(state.endpoints, endpoint, 1, &(&1 + 1))
     }}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    sent = send_batch(state)
    {:reply, sent, empty()}
  end

  @impl true
  def handle_info(:tick, state) do
    send_batch(state)
    schedule()
    {:noreply, empty()}
  end

  defp schedule, do: Process.send_after(self(), :tick, @every)

  # An idle service says nothing. Reporting zero every ten seconds would fill a
  # dashboard with the absence of news.
  defp send_batch(%{calls: 0}), do: %{}

  defp send_batch(state) do
    # The busiest endpoint of the interval, as one label. Sending a breakdown
    # would mean one ping per endpoint, which is the batching we just avoided.
    busiest =
      state.endpoints
      |> Enum.max_by(fn {_endpoint, count} -> count end, fn -> {nil, 0} end)
      |> elem(0)

    attrs = [
      endpoint: busiest,
      calls: state.calls,
      units: state.units,
      found: state.found,
      cached: state.cached
    ]

    Ssa.ping("lookups", attrs)
    Map.new(attrs)
  end

  defp empty,
    do: %{calls: 0, units: 0, found: 0, cached: 0, endpoints: %{}}
end
