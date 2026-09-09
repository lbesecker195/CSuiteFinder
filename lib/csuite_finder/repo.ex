defmodule CsuiteFinder.Repo do
  use Ecto.Repo,
    otp_app: :csuite_finder,
    adapter: Ecto.Adapters.Postgres
end
