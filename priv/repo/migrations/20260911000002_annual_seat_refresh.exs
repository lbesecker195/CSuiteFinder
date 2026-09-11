defmodule CsuiteFinder.Repo.Migrations.AnnualSeatRefresh do
  @moduledoc """
  What an annual seat needs in order to be granted monthly.

  A monthly seat grants when its invoice is paid, and the two line up. An annual
  seat is invoiced once and owes twelve monthly grants, so the grant can no
  longer be driven by the payment — it needs to know the billing interval, and
  it needs to remember which month it last granted for, or a restart would grant
  the same month twice.
  """

  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      # "month" or "year". Monthly is the default because that is what every
      # existing row is: they were created when it was the only plan.
      add :interval, :string, null: false, default: "month"

      # The first day of the month this subscription has already been granted
      # for. Held as a date rather than a timestamp so "have we done this month"
      # is an equality test, not an arithmetic one.
      add :refreshed_for, :date
    end

    # The refresher scans for work by these three together.
    create index(:subscriptions, [:interval, :status, :refreshed_for])
  end
end
