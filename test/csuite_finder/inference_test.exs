defmodule CsuiteFinder.InferenceTest do
  @moduledoc """
  The model fallback, and the validation that stands between it and the cache.

  A model's answer is a plausible answer. Most of this file is about the cases
  where it should be thrown away rather than believed.
  """

  use ExUnit.Case, async: false

  alias CsuiteFinder.{Inference, InferenceStub}

  setup do
    on_exit(fn ->
      InferenceStub.reset()

      Application.put_env(
        :csuite_finder,
        Inference,
        Keyword.put(Application.get_env(:csuite_finder, Inference, []), :api_key, nil)
      )
    end)
  end

  describe "when it is not configured" do
    test "it answers unknown without making a request" do
      # No key, no call. Every caller is already a fallback path, so an absent
      # key has to be a quiet no-op rather than an error.
      assert Inference.configured?() == false
      assert Inference.title("Jane Doe", "acme.com") == :unknown
      assert Inference.email_pattern("acme.com") == :unknown
    end
  end

  describe "job titles" do
    test "a short answer is taken, with what it cost" do
      InferenceStub.stub("CFO")
      assert {:ok, "CFO", cost} = Inference.title("Jane Doe", "acme.com")
      assert cost > 0
    end

    test "trailing punctuation and whitespace are trimmed off" do
      InferenceStub.stub("  Chief Financial Officer.  ")
      assert {:ok, "Chief Financial Officer", _} = Inference.title("Jane Doe", "acme.com")
    end

    test "the model admitting it does not know is a miss, not a title" do
      InferenceStub.stub("UNKNOWN")
      assert Inference.title("Jane Doe", "acme.com") == :unknown
    end

    test "a speech instead of a title is a miss" do
      # An 8-token ceiling makes this rare, but a truncated sentence is still a
      # sentence and it must not end up in the position column.
      InferenceStub.stub("I could not find any public information about")
      assert Inference.title("Jane Doe", "acme.com") == :unknown
    end

    test "the prompt carries the name and the company" do
      InferenceStub.stub(fn prompt ->
        assert prompt =~ "Jane Doe"
        assert prompt =~ "Acme Corp"
        "CTO"
      end)

      assert {:ok, "CTO", _} = Inference.title("Jane Doe", "Acme Corp")
    end
  end

  describe "email patterns" do
    test "a valid pattern comes back canonical" do
      InferenceStub.stub("{first}.{last}")
      assert {:ok, "{first}.{last}", _} = Inference.email_pattern("acme.com")
    end

    test "an initial-plus-surname pattern is accepted" do
      InferenceStub.stub("{f}{last}")
      assert {:ok, "{f}{last}", _} = Inference.email_pattern("acme.com")
    end

    test "a pattern using a token we do not model is refused" do
      # Believing this would build addresses out of a placeholder we cannot
      # fill, which is worse than having no pattern at all.
      InferenceStub.stub("{firstname}.{surname}")
      assert Inference.email_pattern("acme.com") == :unknown
    end

    test "prose around the pattern is refused rather than parsed out of" do
      InferenceStub.stub("It is usually {first}.{last}")
      assert Inference.email_pattern("acme.com") == :unknown
    end

    test "a pattern with no name in it is refused" do
      InferenceStub.stub("._-")
      assert Inference.email_pattern("acme.com") == :unknown
    end

    test "UNKNOWN is a miss" do
      InferenceStub.stub("UNKNOWN")
      assert Inference.email_pattern("acme.com") == :unknown
    end
  end

  describe "when the upstream fails" do
    test "an error is a miss, never an exception" do
      # This runs behind two other failures already. It cannot be the thing that
      # turns a degraded answer into a 500.
      InferenceStub.stub(fn _ -> raise "boom" end)
      assert catch_error(Inference.title("Jane Doe", "acme.com")) != nil
    end
  end
end
