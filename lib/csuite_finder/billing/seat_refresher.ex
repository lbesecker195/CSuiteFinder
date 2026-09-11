defmodule CsuiteFinder.Billing.SeatRefresher do
  @moduledoc """
  Tops annual seats back up each month.

  A monthly seat is granted by its own payment. An annual seat is paid once and
  owes twelve monthly grants, so eleven of them have no payment to ride on and
  something has to hand them out. That is this.

  It is a plain timer rather than a job queue because that is the whole job: a
  scan of a handful of rows, on the hour. The correctness does not live here —
  it lives in `Subscriptions.refresh_annual_seats/1`, which claims each month
  with a conditional UPDATE before granting it. So a tick that fires twice, or
  fires on three nodes at once, grants once. This process only has to make sure
  a tick happens at all.

  It runs hourly rather than daily on purpose. A daily tick that fails leaves a
  customer without credit until tomorrow; an hourly one that fails is retried in
  an hour, and granting the same month twice is already impossible.
  """

  use GenServer

  require Logger

  alias CsuiteFinder.Billing.Subscriptions

  @every :timer.hours(1)
  # Long enough that migrations and the endpoint are up before the first scan,
  # short enough that a deploy does not skip a month boundary.
  @first_run :timer.seconds(30)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run a scan now and return how many seats were topped up. For tests and ops."
  @spec run_now() :: non_neg_integer()
  def run_now, do: Subscriptions.refresh_annual_seats()

  @impl true
  def init(_opts) do
    Process.send_after(self(), :refresh, @first_run)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    # A failure here must not take the process down: the next tick is an hour
    # away and would fix it, whereas a crash loop would keep restarting the
    # timer from zero and never reach the scan.
    try do
      case Subscriptions.refresh_annual_seats() do
        0 -> :ok
        n -> Logger.info("seat refresher: topped up #{n} annual seat(s)")
      end
    rescue
      error ->
        Logger.error("seat refresher failed: #{Exception.message(error)}")
    end

    Process.send_after(self(), :refresh, @every)
    {:noreply, state}
  end
end
