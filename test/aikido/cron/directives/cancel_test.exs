defmodule AikidoTest.Cron.Directives.CancelTest do
  use ExUnit.Case, async: true

  alias Aikido.Directives

  describe "Aikido.Cron.Directives.Cancel directive creation" do
    test "creates cron cancel directive with atom job_id" do
      directive = %Aikido.Cron.Directives.Cancel{job_id: :heartbeat}

      assert %Aikido.Cron.Directives.Cancel{} = directive
      assert directive.job_id == :heartbeat
    end

    test "creates cron cancel directive with string job_id" do
      directive = %Aikido.Cron.Directives.Cancel{job_id: "daily_cleanup"}

      assert directive.job_id == "daily_cleanup"
    end

    test "creates cron cancel directive with reference job_id" do
      ref = make_ref()
      directive = %Aikido.Cron.Directives.Cancel{job_id: ref}

      assert directive.job_id == ref
    end

    test "creates cron cancel directive with integer job_id" do
      directive = %Aikido.Cron.Directives.Cancel{job_id: 123}

      assert directive.job_id == 123
    end
  end

  describe "Directives.cron_cancel/1 helper" do
    test "creates cron cancel directive with atom" do
      directive = Directives.cron_cancel(:heartbeat)

      assert %Aikido.Cron.Directives.Cancel{} = directive
      assert directive.job_id == :heartbeat
    end

    test "creates cron cancel directive with string" do
      directive = Directives.cron_cancel("daily_cleanup")

      assert directive.job_id == "daily_cleanup"
    end

    test "creates cron cancel directive with reference" do
      ref = make_ref()
      directive = Directives.cron_cancel(ref)

      assert directive.job_id == ref
    end

    test "accepts any term as job_id" do
      test_ids = [
        :atom_id,
        "string_id",
        123,
        make_ref(),
        {:tuple, "id"},
        ["list", "id"]
      ]

      for id <- test_ids do
        directive = Directives.cron_cancel(id)
        assert %Aikido.Cron.Directives.Cancel{} = directive
        assert directive.job_id == id
      end
    end
  end

  describe "schema validation" do
    test "has valid schema" do
      assert Ash.Type.ash_type?(Aikido.Cron.Directives.Cancel)
    end

    test "enforces required job_id key" do
      assert_raise ArgumentError, fn ->
        struct!(Aikido.Cron.Directives.Cancel, %{})
      end
    end

    test "allows valid struct creation" do
      directive = %Aikido.Cron.Directives.Cancel{job_id: :test}
      assert directive.job_id == :test
    end
  end
end
