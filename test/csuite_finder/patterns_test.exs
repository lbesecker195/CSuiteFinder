defmodule CsuiteFinder.PatternsTest do
  use ExUnit.Case, async: true

  alias CsuiteFinder.Patterns

  describe "from_provider/1" do
    test "translates provider notation into canonical tokens" do
      assert {:ok, "{first}.{last}"} = Patterns.from_provider("[F].[L]")
      assert {:ok, "{f}{last}"} = Patterns.from_provider("[F1][L]")
      assert {:ok, "{first}"} = Patterns.from_provider("[F]")
      assert {:ok, "{first}{l}"} = Patterns.from_provider("[F][L1]")
      assert {:ok, "{first:2}{last}"} = Patterns.from_provider("[F2][L]")
    end

    test "refuses a token it does not model rather than guessing" do
      assert {:error, :unsupported} = Patterns.from_provider("[X][L]")
    end
  end

  describe "build/3" do
    test "builds an address from a pattern" do
      assert {:ok, "patrick@stripe.com"} =
               Patterns.build("{first}", "Patrick Collison", "stripe.com")

      assert {:ok, "pcollison@stripe.com"} =
               Patterns.build("{f}{last}", "Patrick Collison", "stripe.com")

      assert {:ok, "patrick.collison@stripe.com"} =
               Patterns.build("{first}.{last}", "Patrick Collison", "stripe.com")
    end

    test "keeps separators intact while folding accents" do
      assert {:ok, "jose.alvarez@acme.com"} =
               Patterns.build("{first}.{last}", "José Álvarez", "acme.com")
    end

    test "fails when the pattern needs a name part the person lacks" do
      assert {:error, :missing_part} = Patterns.build("{first}.{last}", "Cher", "acme.com")
    end

    test "strips characters that cannot appear in a local-part" do
      assert {:ok, "obrien@acme.com"} = Patterns.build("{last}", "Conan O'Brien", "acme.com")
    end
  end

  describe "derive/2" do
    test "recovers the pattern from an address and its owner" do
      assert {:ok, "{first}.{last}"} =
               Patterns.derive("patrick.collison@stripe.com", "Patrick Collison")

      assert {:ok, "{f}{last}"} = Patterns.derive("pcollison@stripe.com", "Patrick Collison")
      assert {:ok, "{first}"} = Patterns.derive("patrick@stripe.com", "Patrick Collison")
    end

    test "returns no_match when the address does not fit the name" do
      assert {:error, :no_match} = Patterns.derive("zzz@stripe.com", "Patrick Collison")
    end
  end

  describe "invert/2" do
    test "reads both names out of a separated pattern" do
      assert {:ok, %{first: "john", last: "smith"}} =
               Patterns.invert("john.smith", "{first}.{last}")
    end

    test "reads a surname and an initial out of an flast pattern" do
      assert {:ok, names} = Patterns.invert("mbenioff", "{f}{last}")
      assert names[:last] == "benioff"
      assert names[:first_initial] == "m"
      refute names[:first]
    end

    test "refuses to split an unseparated two-name pattern" do
      assert {:error, :ambiguous} = Patterns.invert("johnsmith", "{first}{last}")
    end

    test "returns no_match when the local-part does not fit" do
      assert {:error, :no_match} = Patterns.invert("john_smith", "{first}.{last}")
    end
  end
end
