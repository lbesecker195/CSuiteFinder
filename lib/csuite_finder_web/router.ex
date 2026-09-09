defmodule CsuiteFinderWeb.Router do
  use CsuiteFinderWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug CsuiteFinderWeb.Plugs.Timing
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  # Authenticated + metered: everything that can spend money.
  pipeline :metered do
    plug CsuiteFinderWeb.Plugs.ApiAuth
    plug CsuiteFinderWeb.Plugs.RequireFunds
  end

  pipeline :authenticated do
    plug CsuiteFinderWeb.Plugs.ApiAuth
  end

  # Operator-only, behind a shared token (see Plugs.AdminAuth).
  pipeline :admin do
    plug CsuiteFinderWeb.Plugs.AdminAuth
  end

  scope "/csuitefinder", CsuiteFinderWeb do
    pipe_through [:api, :metered]

    # Both verbs, because these get called from scripts and from browsers alike.
    get "/email/find", EmailController, :find
    post "/email/find", EmailController, :find

    get "/email/deliverable", EmailController, :deliverable
    post "/email/deliverable", EmailController, :deliverable

    get "/email/enrich", EmailController, :enrich
    post "/email/enrich", EmailController, :enrich

    get "/email/pattern", EmailController, :pattern
    post "/email/pattern", EmailController, :pattern

    get "/email/name", EmailNameController, :name
    post "/email/name", EmailNameController, :name

    # The original path. Kept working because it is published in the treg
    # catalog listing, and a listed endpoint that 404s fails their verification
    # — and would break any agent that had already learned it.
    get "/name/who", EmailNameController, :name
    post "/name/who", EmailNameController, :name

    get "/company/info", CompanyController, :info
    post "/company/info", CompanyController, :info

    get "/company/find", CompanyController, :find
    post "/company/find", CompanyController, :find

    get "/company/people", ProspectController, :people
    post "/company/people", ProspectController, :people

    get "/email/company/people", ProspectController, :emails
    post "/email/company/people", ProspectController, :emails

    get "/phone/find", PhoneController, :find
    post "/phone/find", PhoneController, :find

    get "/phone/valid", PhoneController, :valid
    post "/phone/valid", PhoneController, :valid

    get "/phone/name", PhoneController, :name
    post "/phone/name", PhoneController, :name

    get "/phone/enrich", PhoneController, :enrich
    post "/phone/enrich", PhoneController, :enrich

    get "/phone/company", PhoneController, :company
    post "/phone/company", PhoneController, :company
  end

  scope "/csuitefinder", CsuiteFinderWeb do
    pipe_through [:api, :authenticated]

    get "/keys", KeyController, :index
    post "/keys", KeyController, :create
    delete "/keys/:id", KeyController, :delete

    get "/billing/balance", BillingController, :balance
    get "/billing/usage", BillingController, :usage
    post "/billing/topup", BillingController, :topup
    post "/billing/capture", BillingController, :capture
  end

  # /ops names every upstream we buy from and prices our margin. It is operator
  # data, so it sits behind the admin token rather than any customer's API key.
  scope "/csuitefinder", CsuiteFinderWeb do
    pipe_through [:api, :admin]

    get "/ops/costs", OpsController, :costs
    get "/ops/cache", OpsController, :cache
  end

  # PayPal calls this one; it authenticates itself by signature instead.
  scope "/csuitefinder", CsuiteFinderWeb do
    pipe_through :api

    post "/billing/webhook", BillingController, :webhook
    post "/register", RegistrationController, :create
    get "/health", HealthController, :index
    get "/pricing", PageController, :pricing
  end

  scope "/admin", CsuiteFinderWeb do
    pipe_through [:browser, :admin]

    get "/", AdminController, :index
  end

  scope "/admin", CsuiteFinderWeb do
    pipe_through [:api, :admin]

    get "/metrics.json", AdminController, :metrics
  end

  # The landing page.
  scope "/", CsuiteFinderWeb do
    pipe_through :browser

    get "/", PageController, :index
    get "/account", AccountController, :index
    get "/teams", PageController, :teams
    get "/start", PageController, :start
    get "/llms.txt", PageController, :llms
  end
end
