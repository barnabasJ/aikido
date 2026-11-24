defmodule Aikido.Dsl.ExplicitRouteMountTest.PublicSignal do
  use Aikido.Signal

  signal do
    type "mount.public"
  end
end

defmodule Aikido.Dsl.ExplicitRouteMountTest do
  use ExUnit.Case, async: true

  defp compile_agent(routes, actions \\ "") do
    module = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Aikido.Agent
      agent do
        name "bound_route"
        slice :thread, Aikido.Thread.Slice
        slice :other_thread, Aikido.Thread.Slice
        #{routes}
      end
      #{actions}
    end
    """)

    module
  end

  test "unknown mount is rejected for a generated implementation route" do
    assert_raise Spark.Error.DslError, ~r/must identify one declared slice mount/, fn ->
      compile_agent("""
      route Aikido.Thread.Signals.Clear, Aikido.Thread.Actions.Clear,
        mount: :missing, public?: false
      """)
    end
  end

  test "unknown mount is also rejected for an explicit native action reference" do
    assert_raise Spark.Error.DslError, ~r/must identify one declared slice mount/, fn ->
      compile_agent("""
      route "custom.clear", {Aikido.Thread.Slice, :clear},
        mount: :missing, public?: false
      """)
    end
  end

  test "one action cannot be bound to two mounts even with identical resource types" do
    assert_raise Spark.Error.DslError, ~r/ambiguous mount ownership/, fn ->
      compile_agent("""
      route Aikido.Thread.Signals.Clear, Aikido.Thread.Actions.Clear,
        mount: :thread, name: :custom_clear, public?: false
      route Aikido.Thread.Signals.Clear, Aikido.Thread.Actions.Clear,
        mount: :other_thread, name: :custom_clear, public?: false
      """)
    end
  end

  test "a binding cannot silently reuse an action already owned by other mounts" do
    assert_raise Spark.Error.DslError, ~r/ambiguous mount ownership/, fn ->
      compile_agent("""
      route "custom.clear", {Aikido.Thread.Slice, :clear},
        mount: :thread, public?: false
      """)
    end
  end

  test "explicit native action must declare the mounted state resource" do
    assert_raise Spark.Error.DslError, ~r/requires a :state argument typed as/, fn ->
      compile_agent(
        """
        route "custom.clear", :custom_clear, mount: :thread, public?: false
        """,
        """
        actions do
          action :custom_clear, Aikido.Types.ActionResult do
            argument :state, :term
            run Aikido.Thread.Actions.Clear
          end
        end
        """
      )
    end
  end

  test "a public implementation route retains its binding after command alias generation" do
    module =
      compile_agent("""
      route Aikido.Dsl.ExplicitRouteMountTest.PublicSignal, Aikido.Thread.Actions.Clear,
        mount: :thread, name: :custom_clear
      """)

    route =
      module
      |> Spark.Dsl.Extension.get_persisted(:aikido_agent_routes)
      |> Enum.find(&(&1.mount == :thread))

    assert Aikido.Agent.Info.slice_paths_for_action(module)[route.action] == [:thread]
    {^module, name} = route.action
    argument = Enum.find(Ash.Resource.Info.action(module, name).arguments, &(&1.name == :state))
    assert argument.constraints[:instance_of] == Aikido.Thread.Slice
  end

  test "an app-owned native action with a Thread struct argument can target Thread" do
    module =
      compile_agent(
        """
        route "custom.clear", :custom_clear, mount: :thread, public?: false
        """,
        """
        actions do
          action :custom_clear, Aikido.Types.ActionResult do
            argument :state, :struct do
              constraints instance_of: Aikido.Thread.Slice
              allow_nil? false
            end
            run Aikido.Thread.Actions.Clear
          end
        end
        """
      )

    assert Aikido.Agent.Info.slice_paths_for_action(module)[{module, :custom_clear}] == [:thread]
  end
end
