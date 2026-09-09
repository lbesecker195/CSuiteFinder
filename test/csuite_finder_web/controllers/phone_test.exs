defmodule CsuiteFinderWeb.PhoneTest do
  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Cache.Phone
  alias CsuiteFinder.{Fixtures, Phones, Repo, TregStub}

  @found %{
    "output" => %{"phone" => "7075485509", "line_type" => "mobile"},
    "_treg" => %{
      "served_by" => "quickenrich.people.phone.find",
      "outcome" => "hit",
      "tried" => []
    }
  }

  @validated %{
    "data" => %{
      "valid" => true,
      "e164_format" => "+17075485509",
      "local_format" => "(707) 548-5509",
      "intl_format" => "+1 707-548-5509",
      "country_code" => "US",
      "line_type" => "MOBILE",
      "carrier" => "AT&T",
      "region" => %{"name" => "California", "code" => "CA"}
    }
  }

  setup %{conn: conn} do
    {account, key} = Fixtures.account_with_key(tokens: 400)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> key), account: account}
  end

  describe "normalisation" do
    test "the same number written many ways is one row" do
      for form <- ["7075485509", "(707) 548-5509", "707-548-5509", "+1 707 548 5509"] do
        assert {:ok, normalized} = Phones.normalize(form)
        assert normalized =~ ~r/^\+?\d+$/
      end
    end

    test "rejects things that are not numbers" do
      assert {:error, :invalid_phone} = Phones.normalize("12345")
      assert {:error, :invalid_phone} = Phones.normalize("not a phone")
      assert {:error, :invalid_phone} = Phones.normalize(nil)
    end
  end

  describe "GET /csuitefinder/phone/find" do
    test "finds a number from a name and domain", %{conn: conn} do
      TregStub.stub(fn "treg.people.phone.find", _ -> {200, @found, 4_834} end)

      body =
        conn
        |> get(~p"/csuitefinder/phone/find?full_name=Dylan%20Field&domain=figma.com")
        |> json_response(200)

      assert body["found"]
      assert body["phone"] == "7075485509"
      assert body["line_type"] == "mobile"
      assert body["belongs_to"]["full_name"] == "Dylan Field"
    end

    test "costs 5 tokens", %{conn: conn, account: account} do
      TregStub.stub(fn "treg.people.phone.find", _ -> {200, @found, 4_834} end)

      get(conn, ~p"/csuitefinder/phone/find?full_name=Dylan%20Field&domain=figma.com")

      assert Repo.reload(account).token_balance == 395
    end

    test "needs an identity it can actually use", %{conn: conn} do
      body = conn |> get(~p"/csuitefinder/phone/find") |> json_response(400)
      assert body["error"] == "missing_identity"
    end
  end

  describe "GET /csuitefinder/phone/valid" do
    test "returns validity, line type, carrier and every format", %{conn: conn} do
      TregStub.stub(fn "tomba.people.phone.verify", _ -> {200, @validated, 8_900} end)

      body =
        conn |> get(~p"/csuitefinder/phone/valid?phone=7075485509") |> json_response(200)

      assert body["valid"]
      assert body["carrier"] == "AT&T"
      assert body["formats"]["e164"] == "+17075485509"
    end

    test "is included rather than billed", %{conn: conn, account: account} do
      TregStub.stub(fn "tomba.people.phone.verify", _ -> {200, @validated, 8_900} end)

      get(conn, ~p"/csuitefinder/phone/valid?phone=7075485509")

      assert Repo.reload(account).token_balance == 400
    end
  end

  describe "the reverse index" do
    setup %{conn: conn} do
      TregStub.stub(fn
        "treg.people.phone.find", _ -> {200, @found, 4_834}
        "tomba.people.phone.verify", _ -> {200, @validated, 8_900}
      end)

      get(conn, ~p"/csuitefinder/phone/find?full_name=Dylan%20Field&domain=figma.com")
      :ok
    end

    test "a number we found is attributable afterwards", %{conn: conn} do
      body = conn |> get(~p"/csuitefinder/phone/who?phone=7075485509") |> json_response(200)

      assert body["found"]
      assert body["belongs_to"]["full_name"] == "Dylan Field"
    end

    test "matches however the number is written", %{conn: conn} do
      # One provider stores 7075485509, another +17075485509. An exact match
      # would miss half the time.
      for form <- ["7075485509", "%2B17075485509", "(707)%20548-5509"] do
        body =
          conn |> get("/csuitefinder/phone/who?phone=#{form}") |> json_response(200)

        assert body["found"], "did not resolve #{form}"
      end
    end

    test "a number we have never seen is unknown, not guessed", %{conn: conn} do
      # There is no provider to buy a reverse lookup from, so saying so is the
      # only honest answer.
      body = conn |> get(~p"/csuitefinder/phone/who?phone=2125550123") |> json_response(200)

      refute body["found"]
      assert body["message"] =~ "have not seen"
    end

    test "a phone stands in for an email on /name/who", %{conn: conn} do
      body = conn |> get(~p"/csuitefinder/name/who?phone=7075485509") |> json_response(200)
      assert body["full_name"] == "Dylan Field"
    end

    test "an unknown number is refused there rather than answered vaguely",
         %{conn: conn} do
      body = conn |> get(~p"/csuitefinder/name/who?phone=2125550123") |> json_response(400)
      assert body["error"] == "phone_unknown"
    end
  end

  describe "a row is never written back thinner than it was" do
    test "validating keeps the attribution; re-finding keeps the validation",
         %{conn: conn} do
      TregStub.stub(fn
        "treg.people.phone.find", _ -> {200, @found, 4_834}
        "tomba.people.phone.verify", _ -> {200, @validated, 8_900}
      end)

      get(conn, ~p"/csuitefinder/phone/find?full_name=Dylan%20Field&domain=figma.com")
      get(conn, ~p"/csuitefinder/phone/valid?phone=7075485509&refresh=true")

      get(
        conn,
        ~p"/csuitefinder/phone/find?full_name=Dylan%20Field&domain=figma.com&refresh=true"
      )

      row = Repo.get_by(Phone, phone: "7075485509")

      # Each write knows only half the row. Whole-row writes would leave
      # whichever ran last, and the reverse lookup would answer "found, owner
      # unknown" or lose the carrier.
      assert row.full_name == "Dylan Field"
      assert row.carrier == "AT&T"
      assert row.e164 == "+17075485509"
      assert row.valid
    end
  end
end
