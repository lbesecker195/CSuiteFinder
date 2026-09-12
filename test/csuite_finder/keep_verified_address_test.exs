defmodule CsuiteFinder.KeepVerifiedAddressTest do
  @moduledoc """
  An address a customer brings us and pays to check is an address we then know.

  It used to be checked, billed, answered and forgotten, so the next person to
  ask about that domain paid a provider to rediscover something our own SMTP
  check had already confirmed. It is kept now — but only when keeping it makes
  the corpus better, which is a narrower case than "whenever one is verified".
  """

  use CsuiteFinder.DataCase, async: true

  import Ecto.Query

  alias CsuiteFinder.Cache.CompanyPerson
  alias CsuiteFinder.Finder
  alias CsuiteFinder.Repo

  defp held(email) do
    Repo.one(from p in CompanyPerson, where: p.email == ^email)
  end

  describe "a deliverable address we did not have" do
    test "is kept, against its domain" do
      assert Finder.record_verification("dana.reid@acme.com", "deliverable", false) == :ok

      row = held("dana.reid@acme.com")

      assert row.domain == "acme.com"

      assert row.kind == "verified",
             "provenance has to survive, for the admin split and for pruning"

      # We know it is live and where it works. We do not know whose it is, and a
      # name invented to make the row look complete is how a corpus stops being
      # worth anything.
      assert is_nil(row.full_name)
    end

    test "and counts toward the corpus, which is the point of keeping it" do
      before = Repo.aggregate(CompanyPerson, :count)
      Finder.record_verification("new.person@acme.com", "deliverable", false)

      assert Repo.aggregate(CompanyPerson, :count) == before + 1
    end
  end

  describe "what it refuses to keep" do
    test "an undeliverable address, which is a bounce, not a contact" do
      Finder.record_verification("gone@acme.com", "undeliverable", false)

      refute held("gone@acme.com")
    end

    test "an address on a catch-all domain, where the tick means nothing" do
      # The server accepts everything, so acceptance is not evidence the mailbox
      # exists — the same reason pattern learning refuses these.
      Finder.record_verification("anything@catchall.com", "deliverable", true)

      refute held("anything@catchall.com")
    end

    test "an unknown verdict, where nothing was learned" do
      Finder.record_verification("maybe@acme.com", "unknown", false)

      refute held("maybe@acme.com")
    end
  end

  describe "an address we already hold" do
    test "keeps the richer record rather than being flattened by this one" do
      {:ok, _} =
        %CompanyPerson{}
        |> CompanyPerson.changeset(%{
          domain: "acme.com",
          email: "cfo@acme.com",
          full_name: "Robin Vale",
          position: "Chief Financial Officer",
          kind: "provider"
        })
        |> Repo.insert()

      Finder.record_verification("cfo@acme.com", "deliverable", false)

      row = held("cfo@acme.com")

      assert row.full_name == "Robin Vale", "a roster row was overwritten by a bare address"
      assert row.position == "Chief Financial Officer"
      assert row.kind == "provider"

      assert Repo.aggregate(from(p in CompanyPerson, where: p.email == "cfo@acme.com"), :count) ==
               1
    end
  end

  describe "rubbish in" do
    test "an address with no domain is not stored, and does not raise" do
      assert Finder.record_verification("not-an-address", "deliverable", false) == :ok
      assert Repo.aggregate(CompanyPerson, :count) == 0
    end
  end
end
