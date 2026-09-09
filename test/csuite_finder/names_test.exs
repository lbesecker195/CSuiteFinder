defmodule CsuiteFinder.NamesTest do
  use ExUnit.Case, async: true

  alias CsuiteFinder.Names

  describe "split/1" do
    test "splits a plain first and last name" do
      assert {:ok, %{first: "patrick", last: "collison", middle: nil}} =
               Names.split("Patrick Collison")
    end

    test "handles 'Last, First' inversion" do
      assert {:ok, %{first: "patrick", last: "collison"}} = Names.split("Collison, Patrick")
    end

    test "does not mistake a suffix for an inverted surname" do
      assert {:ok, %{first: "john", last: "smith"}} = Names.split("John Smith, Jr")
    end

    test "keeps surname particles with the surname" do
      assert {:ok, %{first: "ludwig", last: "vanbeethoven"}} =
               Names.split("Ludwig van Beethoven")

      assert {:ok, %{last: "delacruz"}} = Names.split("Maria de la Cruz")
    end

    test "folds accents to ASCII" do
      assert {:ok, %{first: "jose", last: "alvarez-nunez"}} = Names.split("José Álvarez-Núñez")
    end

    test "strips titles" do
      assert {:ok, %{first: "john", last: "smith"}} = Names.split("Dr. John Smith")
    end

    test "captures a middle name" do
      assert {:ok, %{first: "mary", middle: "jane", last: "watson"}} =
               Names.split("Mary Jane Watson")
    end

    test "accepts a mononym with no surname" do
      assert {:ok, %{first: "cher", last: nil}} = Names.split("Cher")
    end

    test "rejects an empty name" do
      assert {:error, :unparseable} = Names.split("   ")
      assert {:error, :unparseable} = Names.split(nil)
    end
  end

  describe "name_key/1" do
    test "collapses spelling and ordering variants onto one cache key" do
      key = Names.name_key("Patrick Collison")
      assert Names.name_key("  PATRICK   collison ") == key
      assert Names.name_key("Collison, Patrick") == key
    end

    test "distinguishes different people" do
      refute Names.name_key("Patrick Collison") == Names.name_key("John Collison")
    end
  end
end
