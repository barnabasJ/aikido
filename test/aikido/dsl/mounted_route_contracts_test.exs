defmodule Aikido.Dsl.MountedRouteContractsTest.Increment do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | count: state.count + input.arguments.amount})
  end
end

defmodule Aikido.Dsl.MountedRouteContractsTest.Remote do
  use Aikido.Slice

  slice do
    name "remote_routes"
  end

  actions do
    action :remote, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run Aikido.Dsl.MountedRouteContractsTest.Increment
    end

    action :private_remote, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :amount, :integer, default: 1
      run Aikido.Dsl.MountedRouteContractsTest.Increment
    end
  end
end

defmodule Aikido.Dsl.MountedRouteContractsTest.PrivateIncrement do
  use Aikido.Signal

  signal do
    type "mounted.private_typed"

    schema do
      attribute :amount, :integer do
        description "Amount handled through the internal typed route."
        default 1
      end
    end
  end
end

defmodule Aikido.Dsl.MountedRouteContractsTest.Counter do
  use Aikido.Slice

  slice do
    name "mounted_routes"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 0
      end
    end

    route "mounted.local", {__MODULE__, :local}
    route "mounted.remote", {Aikido.Dsl.MountedRouteContractsTest.Remote, :remote}
    route "mounted.private", {Aikido.Dsl.MountedRouteContractsTest.Remote, :private_remote}
    route "mounted.internal", :internal, public?: false

    route Aikido.Dsl.MountedRouteContractsTest.PrivateIncrement, :typed_internal, public?: false

    route "mounted.matched", :matched,
      match: fn signal -> signal.data[:allowed] == true end,
      priority: -15

    route "mounted.first", :multiple
    route "mounted.second", {__MODULE__, :multiple}

    route "mounted.distinct", :local, priority: -12
    route "mounted.distinct", :local, priority: -13

    route "mounted.distinct", :local,
      match: fn signal -> signal.data[:first] == true end,
      priority: -12

    route "mounted.distinct", :local,
      match: fn signal -> signal.data[:second] == true end,
      priority: -12

    route "mounted.distinct", {Aikido.Dsl.MountedRouteContractsTest.Remote, :remote},
      priority: -12
  end

  actions do
    for name <- [:internal, :typed_internal] do
      action name, Aikido.Types.ActionResult do
        public? true
        argument :state, :term
        argument :amount, :integer, default: 1
        run Aikido.Dsl.MountedRouteContractsTest.Increment
      end
    end

    action :local, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run Aikido.Dsl.MountedRouteContractsTest.Increment
    end

    action :matched, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      argument :allowed, :boolean, default: false
      run Aikido.Dsl.MountedRouteContractsTest.Increment
    end

    action :multiple, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run Aikido.Dsl.MountedRouteContractsTest.Increment
    end
  end
end

defmodule Aikido.Dsl.MountedRouteContractsTest do
  use ExUnit.Case, async: false

  alias Aikido.Dsl.MountedRouteContractsTest.Counter
  alias Aikido.Dsl.MountedRouteContractsTest.Remote

  setup do
    start_supervised!(
      {Aikido, name: __MODULE__.Runtime, durable: AikidoTest.Case.durable_options()}
    )

    resource = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")
    domain = Module.concat(resource, Domain)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(resource)} do
          use Aikido.Agent, domain: #{inspect(domain)}
          agent do
            name "mounted_route_contracts"
            instance #{inspect(__MODULE__.Runtime)}
            schema do
              attribute :count, :integer do
                description "Current counter value updated by routed signals."
                default 100
              end
            end
            slice :counter, #{inspect(Counter)}
            slice :other, #{inspect(Counter)}
          end
        end
        defmodule #{inspect(domain)} do
          use Ash.Domain, extensions: [Aikido.Domain.Extension], validate_config_inclusion?: false
          agents do
            agent :counter, #{inspect(resource)}
          end
        end
        """)
      end)

    assert output == ""
    reference = apply(domain, :counter_start!, [%{}])
    %{resource: resource, domain: domain, reference: reference}
  end

  test "local and remote tuples expose native public domain commands", context do
    %{resource: resource, domain: domain, reference: reference} = context

    assert Ash.Resource.Info.action(resource, :local)
    assert Ash.Resource.Info.action(resource, :remote)
    refute Ash.Resource.Info.action(resource, :private_remote)
    refute function_exported?(domain, :counter_private_remote, 2)

    assert {:ok, _} = apply(domain, :counter_local, [reference, %{amount: "2"}])
    assert {:ok, _} = apply(domain, :counter_remote, [reference, %{amount: "3"}])
    assert_counts(reference, 5)

    for {type, expected} <- [{"mounted.local", 7}, {"mounted.remote", 9}] do
      assert {:ok, _} = raw_signal(reference, type, %{amount: "2"})
      assert_counts(reference, expected)
    end

    assert Aikido.Agent.Info.slice_paths_for_action(resource)[{Remote, :remote}] ==
             [:counter, :other]
  end

  test "matched public commands preserve predicates, priority and mount ownership", context do
    %{resource: resource, domain: domain, reference: reference} = context
    assert Aikido.Agent.Info.signal_routes(resource) == []

    assert Aikido.Agent.Info.slice_paths_for_action(resource)[{Counter, :matched}] ==
             [:counter, :other]

    assert Enum.any?(Aikido.Agent.Info.routes(resource), fn
             {"mounted.matched", predicate, {Counter, :matched}, -15} ->
               is_function(predicate, 1)

             _ ->
               false
           end)

    assert {:error, _} =
             apply(domain, :counter_matched, [reference, %{allowed: false, amount: 9}])

    assert_counts(reference, 0)

    assert {:ok, _} =
             apply(domain, :counter_matched, [reference, %{allowed: true, amount: "2"}])

    assert_counts(reference, 2)
    assert {:error, _} = raw_signal(reference, "mounted.matched", %{allowed: false, amount: 9})
    assert_counts(reference, 2)
    assert {:ok, _} = raw_signal(reference, "mounted.matched", %{allowed: true, amount: "3"})
    assert_counts(reference, 5)
  end

  test "private routes retain delivery without exporting their public native targets", context do
    for name <- [:internal, :typed_internal] do
      assert Ash.Resource.Info.action(Counter, name).public?
      refute Ash.Resource.Info.action(context.resource, name)
      refute function_exported?(context.domain, :"counter_#{name}", 2)
    end

    assert Ash.Resource.Info.action(context.resource, :local).public?
    assert function_exported?(context.domain, :counter_local, 2)

    assert {:ok, _} = raw_signal(context.reference, "mounted.internal", %{amount: "2"})
    assert_counts(context.reference, 2)
    assert {:ok, _} = raw_signal(context.reference, "mounted.private_typed", %{amount: "3"})
    assert_counts(context.reference, 5)
  end

  test "multiple routes share one canonical public command and retain raw delivery", context do
    %{resource: resource, domain: domain, reference: reference} = context

    assert [%{type: "mounted.first", action: {Counter, :multiple}}] =
             resource
             |> Spark.Dsl.Extension.get_entities([:agent])
             |> Enum.filter(&match?(%Aikido.Agent.Route{name: :multiple}, &1))

    assert {:ok, _} = apply(domain, :counter_multiple, [reference, %{amount: "2"}])
    assert_counts(reference, 2)

    for {type, expected} <- [{"mounted.first", 5}, {"mounted.second", 8}] do
      assert {:ok, _} =
               Aikido.AgentServer.call(
                 reference.pid,
                 Aikido.Signal.new!(type, %{amount: "3"}),
                 fn _ -> {:ok, :processed} end
               )

      assert_counts(reference, expected)
    end
  end

  test "normalization removes repeated mount routes and retains every routing distinction",
       context do
    routes = Aikido.Agent.Info.routes(context.resource)
    assert Enum.count(routes, &match?({"mounted.local", {Counter, :local}, -10}, &1)) == 1
    assert Enum.count(routes, &match?({"mounted.remote", {Remote, :remote}, -10}, &1)) == 1
    assert Enum.count(routes, &match?({"mounted.matched", _, {Counter, :matched}, -15}, &1)) == 1

    distinct = Enum.filter(routes, &(elem(&1, 0) == "mounted.distinct"))
    assert length(distinct) == 5
    assert {"mounted.distinct", {Counter, :local}, -12} in distinct
    assert {"mounted.distinct", {Counter, :local}, -13} in distinct
    assert {"mounted.distinct", {Remote, :remote}, -12} in distinct

    predicates =
      for {"mounted.distinct", predicate, {Counter, :local}, -12} <- distinct, do: predicate

    assert [first, second] = predicates
    assert first.(Aikido.Signal.new!("mounted.distinct", %{first: true}))
    refute second.(Aikido.Signal.new!("mounted.distinct", %{first: true}))
    refute first.(Aikido.Signal.new!("mounted.distinct", %{second: true}))
    assert second.(Aikido.Signal.new!("mounted.distinct", %{second: true}))
  end

  test "unrelated public targets still conflict unless explicitly overridden" do
    for override? <- [false, true] do
      resource = Module.concat(__MODULE__, "Conflict#{System.unique_integer([:positive])}")

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule #{inspect(resource)}.Slice do
            use Aikido.Slice
            slice do
              name "conflicting_target"
              route "other.local", :local
            end
            actions do
              action :local, Aikido.Types.ActionResult do
                argument :state, :term
                argument :amount, :integer, default: 1
                run Aikido.Dsl.MountedRouteContractsTest.Increment
              end
            end
          end
          defmodule #{inspect(resource)} do
            use Aikido.Agent
            agent do
              name "conflicting_routes"
              slice :counter, #{inspect(Counter)}
              slice :other, #{inspect(resource)}.Slice
              #{if override?, do: "route \"mounted.local\", {#{inspect(Counter)}, :local}", else: ""}
            end
          end
          """)
        end)

      if override? do
        assert output == ""

        assert [%{action: {Counter, :local}}] =
                 resource
                 |> Spark.Dsl.Extension.get_entities([:agent])
                 |> Enum.filter(&match?(%Aikido.Agent.Route{name: :local}, &1))
      else
        assert output =~ "Public route names must be unique: :local"
      end
    end
  end

  defp raw_signal(reference, type, data) do
    Aikido.AgentServer.call(reference.pid, Aikido.Signal.new!(type, data), fn _ ->
      {:ok, :processed}
    end)
  end

  defp assert_counts(reference, expected) do
    assert {:ok,
            %{state: %{count: 100}, counter: %{count: ^expected}, other: %{count: ^expected}}} =
             Aikido.AgentServer.state(reference.pid, &{:ok, &1.agent.state})
  end
end
