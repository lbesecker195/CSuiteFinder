defmodule CsuiteFinderWeb.PrivacyTest do
  @moduledoc """
  The privacy notice, and that it is reachable from everywhere it has to be.

  A policy nobody can find is the same as no policy, so the links are asserted
  alongside the page itself.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  describe "the policy" do
    test "covers both groups of people whose data is held", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      # Account holders.
      assert html =~ "If you have an account"
      assert html =~ "bcrypt"

      # And the larger group, who never came here and are owed the fuller
      # explanation.
      assert html =~ "If you are someone we found"
      assert html =~ "legitimate interests"
      assert html =~ "right to object"
    end

    test "does not promise an expiry that does not happen", %{conn: conn} do
      # Nothing deletes a cache row on a timer. The TTL decides when the record
      # is re-checked. Saying otherwise would be the one lie in the document.
      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ "it is when we look again, not when"
      assert html =~ "until it is deleted on request"
    end

    test "claims no capability that does not exist", %{conn: conn} do
      # The first draft promised a privacy@ alias nobody had created, a
      # thirty-day answer nothing measured, and by omission implied that
      # analytics waited for permission. A notice is worth less than nothing when
      # it describes a service that is not there.
      html = conn |> get(~p"/privacy") |> html_response(200)

      refute html =~ "privacy@csuitefinder.com"
      refute html =~ "within thirty days"

      assert html =~ "no self-service privacy dashboard"
      assert html =~ "no cookie banner on this"
    end

    test "gives one address for a request", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)
      contact = CsuiteFinderWeb.Layout.privacy_contact()

      assert html =~ ~s(mailto:#{contact})
    end
  end

  describe "finding it" do
    test "every page links to it from the footer", %{conn: conn} do
      for path <- ["/", "/teams", "/developers", "/start", "/checkout", "/privacy"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s(href="/privacy"), "#{path} does not link to the privacy notice"
      end
    end

    test "and the pages that ask for an address say so there", %{conn: conn} do
      # A link in the footer is not notice at the moment someone types their
      # address into a box.
      for path <- ["/account", "/checkout"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ "never reaches us" or html =~ "never reach us",
               "#{path} collects an address without saying what happens to it"

        assert html =~ ~s(href="/privacy")
      end
    end
  end
end
