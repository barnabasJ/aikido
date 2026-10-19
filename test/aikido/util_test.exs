defmodule AikidoTest.UtilTest do
  use AikidoTest.Case, async: true

  alias Aikido.Util

  describe "generate_id/0" do
    test "generates unique non-empty binary identifiers" do
      id1 = Util.generate_id()
      id2 = Util.generate_id()

      assert is_binary(id1)
      assert is_binary(id2)
      assert String.length(id1) > 0
      refute id1 == id2
    end
  end

  describe "validate_name/2" do
    test "validates valid names" do
      assert {:ok, "valid_name"} = Util.validate_name("valid_name")
      assert {:ok, "myAction123"} = Util.validate_name("myAction123")
      assert :ok = Util.validate_name("valid_name", validate: true)
    end

    test "rejects invalid names" do
      invalid_names = ["123action", "invalid-name", "invalid name", 123]

      for name <- invalid_names do
        assert {:error, %Aikido.Error.ValidationError{}} = Util.validate_name(name),
               "expected #{inspect(name)} to be rejected"
      end
    end

    test "rejects invalid names with validate: true option" do
      for name <- ["invalid-name", 123] do
        assert {:error, %Aikido.Error.ValidationError{}} =
                 Util.validate_name(name, validate: true),
               "expected #{inspect(name)} to be rejected with validate: true"
      end
    end
  end

  describe "cond_log/4" do
    test "exercises logging branches and returns :ok" do
      assert :ok = Util.cond_log(:debug, :info, "threshold <= level")
      assert :ok = Util.cond_log(:info, :debug, "threshold > level")
      assert :ok = Util.cond_log(:info, :info, "threshold equals level")
      assert :ok = Util.cond_log(:invalid, :info, "invalid threshold")
      assert :ok = Util.cond_log(:info, :invalid, "invalid level")
      assert :ok = Util.cond_log(:debug, :info, "with opts", domain: [:test])
    end
  end
end
