defmodule CsuiteFinder.SsaTest do
  @moduledoc """
  What may leave the machine in a usage ping.

  These parameters travel in a URL and are written to the logs of every proxy
  between here and the analytics service — their own documentation says so. So
  the interesting assertions are not that the right things are sent, but that
  the wrong ones cannot be, however they are passed in.
  """

  use ExUnit.Case, async: true

  alias CsuiteFinder.Ssa

  describe "what a ping carries" do
    test "the shape of a request, and nothing else" do
      params = Ssa.build("acct_test", "lookup", endpoint: "email.find", cached: true, found: true)

      assert params[:uid] == "acct_test"
      assert params[:event] == "lookup"
      assert params[:endpoint] == "email.find"
      assert params[:cached] == "true"
      assert params[:found] == "true"
    end

    test "and drops anything that is not on the list" do
      params =
        Ssa.build("acct_test", "lookup",
          endpoint: "email.find",
          email: "jane.doe@acme.com",
          domain: "acme.com",
          full_name: "Jane Doe",
          account_id: 42,
          api_key: "csf_live_secret"
        )

      flat = inspect(params)

      refute flat =~ "jane.doe@acme.com"
      refute flat =~ "acme.com"
      refute flat =~ "Jane Doe"
      refute flat =~ "csf_live_secret"
      refute Keyword.has_key?(params, :account_id)
      assert params[:endpoint] == "email.find"
    end

    test "including when the keys arrive as strings" do
      # An allowlist that only matches atoms would pass every string key
      # straight through, which is the shape a params map arrives in.
      params =
        Ssa.build("acct_test", "lookup", %{"email" => "jane@acme.com", "endpoint" => "email.find"})

      refute inspect(params) =~ "jane@acme.com"
      assert params[:endpoint] == "email.find"
    end

    test "and a string key nobody expected does not become an atom" do
      # Atoms are never garbage collected, so turning caller-supplied keys into
      # them is a slow memory leak with a remote trigger.
      before = :erlang.system_info(:atom_count)
      Ssa.build("acct_test", "lookup", %{"totally_novel_key_#{System.unique_integer()}" => "x"})

      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "the company domain" do
    test "is never sent, because it is the customer's business not ours" do
      # Which companies somebody sweeps is the most commercially sensitive thing
      # they do here. It is on no allowlist and this is the test that says why.
      params = Ssa.build("acct_test", "lookup", domain: "stripe.com", endpoint: "company.people")

      refute Keyword.has_key?(params, :domain)
      refute inspect(params) =~ "stripe.com"
    end
  end

  describe "when it is switched off" do
    test "no uid means no ping and no error" do
      assert Ssa.uid() == nil
      refute Ssa.configured?()
      assert Ssa.ping("lookup", endpoint: "email.find") == :ok
    end
  end

  describe "the allowlist itself" do
    test "contains nothing that could identify a person or a company" do
      # A guard on the list rather than on one call: this is what fails if
      # somebody adds `domain` or `email` to it later.
      forbidden = ~w(email domain full_name name account_id api_key key phone
                     linkedin_url ip location city)a

      assert Enum.all?(Ssa.allowed(), &(&1 not in forbidden)),
             "allowlist has grown a field that identifies somebody: " <>
               inspect(Enum.filter(Ssa.allowed(), &(&1 in forbidden)))
    end
  end
end
