defmodule CsuiteFinder.VerdictWordingTest do
  @moduledoc """
  What a deliverability verdict is allowed to be called.

  A catch-all domain is how most large companies are configured, so roughly half
  a corporate list comes back that way. Several upstream verifiers call it
  "risky". Passing that word on means a customer sees half their list flagged as
  dangerous, concludes the data is bad, and stops — when what actually happened
  is that a domain declined to answer a question about one mailbox.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.{Fixtures, TregStub, Verifier}

  setup %{conn: conn} do
    {_account, key} = Fixtures.account_with_key(usd: 5.0, audience: "sales")
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> key)}
  end

  defp verdict(conn, provider_status, address) do
    TregStub.stub(fn "treg.people.email.verify", _ ->
      {200, TregStub.routed(%{"valid" => true, "status" => provider_status}, cost: 1_500), 1_500}
    end)

    conn
    |> post(~p"/csuitefinder/email/deliverable", %{email: address})
    |> json_response(200)
  end

  describe "the word risky" do
    test "never reaches a caller, whatever the provider called it", %{conn: conn} do
      for {signal, i} <- Enum.with_index(~w(risky catch_all catch-all accept_all accept-all)) do
        body = verdict(conn, signal, "person#{i}@acme.com")

        assert body["status"] == "accept_all",
               "#{signal} came back as #{inspect(body["status"])}"

        refute body["status"] =~ "risky"
        refute body["explanation"] =~ "risky"
      end
    end

    test "and it is explained as normal rather than as a warning", %{conn: conn} do
      body = verdict(conn, "catch_all", "someone@acme.com")

      assert body["explanation"] =~ "accepts mail for every address"
      assert body["explanation"] =~ "Normal for large companies"

      # Still not claimed as confirmed. The comfort is in the wording, not in
      # pretending we checked something we could not check — an address sold as
      # verified that then bounces is the one failure this product cannot have.
      refute body["deliverable"]
    end

    test "a confirmed address is stated as safe, not merely not-bad", %{conn: conn} do
      body = verdict(conn, "valid", "real@acme.com")

      assert body["deliverable"]
      assert body["explanation"] =~ "Safe to send"
    end
  end

  describe "the other verdicts" do
    test "a dead one is unambiguous, because that is the one that costs money" do
      assert Verifier.explain("undeliverable") =~ "would bounce"
    end

    test "unchecked is not reported as a failure" do
      assert Verifier.explain("unknown") =~ "Not a failed check"
    end
  end
end
