defmodule AikidoTest.TypedRoutesTest.Increment do
  use Aikido.Signal

  signal do
    type "typed.increment"
    description "Increases the counter by the supplied positive amount."

    schema do
      attribute :amount, :integer do
        default 2
        allow_nil? false
        constraints min: 1
        description "Amount to add"
        sensitive? true
      end
    end
  end
end

defmodule AikidoTest.TypedRoutesTest.Reset do
  use Aikido.Signal

  signal do
    type "typed.reset"

    schema do
      attribute :value, :integer do
        description "Counter value to restore when handling the reset signal."
        default 0
        allow_nil? false
      end
    end
  end
end

defmodule AikidoTest.TypedRoutesTest.Wrapped do
  use Aikido.Signal

  signal do
    type "typed.wrapped"

    schema do
      attribute :data, :term do
        description "Whole signal payload retained for native contract checks."
      end
    end
  end
end

defmodule AikidoTest.TypedRoutesTest.Empty do
  use Aikido.Signal

  signal do
    type "typed.empty"
  end
end

defmodule AikidoTest.TypedRoutesTest.Add do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{
        input.arguments.state
        | count: input.arguments.state.count + input.arguments.amount
      }
    )
  end
end

defmodule AikidoTest.TypedRoutesTest.Change do
  use Ash.Resource.Actions.Implementation

  def run(
        %{arguments: %{data: %Ash.Union{type: :increment, value: payload}}} = input,
        _opts,
        _context
      ) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | count: input.arguments.state.count + payload.amount}
    )
  end

  def run(
        %{arguments: %{data: %Ash.Union{type: :reset, value: payload}}} = input,
        _opts,
        _context
      ) do
    Aikido.Types.ActionResult.new(state: %{input.arguments.state | count: payload.value})
  end
end

defmodule AikidoTest.TypedRoutesTest.Store do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | received: input.arguments.data}
    )
  end
end

defmodule AikidoTest.TypedRoutesTest.Count do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | count: input.arguments.state.count + 1}
    )
  end
end

defmodule AikidoTest.TypedRoutesTest.CounterSlice do
  use Aikido.Slice

  slice do
    name "typed_counter"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 0
        allow_nil? false
      end
    end

    route [AikidoTest.TypedRoutesTest.Increment, AikidoTest.TypedRoutesTest.Reset],
          AikidoTest.TypedRoutesTest.Change
  end
end

defmodule AikidoTest.TypedRoutesTest.ObserverSlice do
  use Aikido.Slice

  slice do
    name "typed_observer"

    schema do
      attribute :count, :integer do
        description "Number of signals observed by the wildcard route."
        default 0
        allow_nil? false
      end
    end

    route "**", AikidoTest.TypedRoutesTest.Count
  end
end

defmodule AikidoTest.TypedRoutesTest.First do
  use Aikido.Signal

  signal do
    type "typed.first"

    schema do
      attribute :data, :term do
        description "Whole signal payload retained for native contract checks."
        default false
      end

      attribute :marker, :string do
        description "Marker distinguishing the selected signal contract."
        default "first"
      end
    end
  end
end

defmodule AikidoTest.TypedRoutesTest.Second do
  use Aikido.Signal

  signal do
    type "typed.second"

    schema do
      attribute :data, :term do
        description "Whole signal payload retained for native contract checks."
      end

      attribute :marker, :string do
        description "Marker distinguishing the selected signal contract."
        default "second"
      end
    end
  end
end

defmodule AikidoTest.TypedRoutesTest.Defaulted do
  use Aikido.Signal

  signal do
    type "typed.defaulted"

    schema do
      attribute :mfa, :integer do
        description "Value supplied by the module-function-arguments default."
        default {__MODULE__, :mfa, []}
        constraints min: 1
      end

      attribute :function, :term do
        description "Value supplied by the function default."
        default &__MODULE__.function/0
      end
    end
  end

  def mfa do
    send(self(), {:payload_default, :mfa})
    3
  end

  def function do
    send(self(), {:payload_default, :function})
    false
  end
end

defmodule AikidoTest.TypedRoutesTest.CaptureUnion do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    state = %{
      input.arguments.state
      | received: %{union: input.arguments.data, original: input.context.aikido.signal.data}
    }

    Aikido.Types.ActionResult.new(state: state)
  end
end

defmodule AikidoTest.TypedRoutesTest.Agent do
  use Aikido.Agent, domain: AikidoTest.TypedRoutesTest.Domain

  agent do
    name "typed_agent"
    instance AikidoTest.TypedRoutesTest.Instance

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 0
        allow_nil? false
        public? true
      end

      attribute :received, :term do
        description "Payload received by the selected native reducer."
        public? true
      end
    end

    route AikidoTest.TypedRoutesTest.Increment, AikidoTest.TypedRoutesTest.Add
    route AikidoTest.TypedRoutesTest.Wrapped, AikidoTest.TypedRoutesTest.Store, name: :store
    route AikidoTest.TypedRoutesTest.Empty, AikidoTest.TypedRoutesTest.Count
    route AikidoTest.TypedRoutesTest.Reset, AikidoTest.TypedRoutesTest.Count, public?: false

    route [AikidoTest.TypedRoutesTest.First, AikidoTest.TypedRoutesTest.Second],
          AikidoTest.TypedRoutesTest.CaptureUnion
  end
end

defmodule AikidoTest.TypedRoutesTest.Mounted do
  use Aikido.Agent

  agent do
    name "typed_mounted"
    instance AikidoTest.TypedRoutesTest.Instance
    slice :first, AikidoTest.TypedRoutesTest.CounterSlice
    slice :second, AikidoTest.TypedRoutesTest.CounterSlice
    slice :observer, AikidoTest.TypedRoutesTest.ObserverSlice
  end
end

defmodule AikidoTest.TypedRoutesTest.PublicSlice do
  use Aikido.Slice

  slice do
    name "public_route_slice"

    schema do
      attribute :count, :integer do
        description "Counter used to compare public and private route delivery."
        default 0
        allow_nil? false
      end
    end

    route AikidoTest.TypedRoutesTest.Increment, AikidoTest.TypedRoutesTest.Add
    route AikidoTest.TypedRoutesTest.Reset, AikidoTest.TypedRoutesTest.Count, public?: false
  end
end

defmodule AikidoTest.TypedRoutesTest.PublicMounted do
  use Aikido.Agent, domain: AikidoTest.TypedRoutesTest.Domain

  agent do
    name "public_route_mounted"
    instance AikidoTest.TypedRoutesTest.Instance
    slice :counter, AikidoTest.TypedRoutesTest.PublicSlice
  end
end

defmodule AikidoTest.TypedRoutesTest.Domain do
  use Ash.Domain, extensions: [Aikido.Ash.Domain], validate_config_inclusion?: false

  agents do
    agent :counter, AikidoTest.TypedRoutesTest.PublicMounted
    agent :direct, AikidoTest.TypedRoutesTest.Agent
  end
end

defmodule AikidoTest.TypedRoutesTest do
  use ExUnit.Case, async: false

  alias AikidoTest.TypedRoutesTest.Agent, as: Resource
  alias AikidoTest.TypedRoutesTest.CounterSlice
  alias AikidoTest.TypedRoutesTest.Mounted

  setup do
    start_supervised!(
      {Aikido,
       name: AikidoTest.TypedRoutesTest.Instance, durable: AikidoTest.Case.durable_options()}
    )

    :ok
  end

  test "typed agent routes infer public commands and keep private routes deliverable" do
    assert Ash.Resource.Info.action(Resource, :increment).public?
    refute Ash.Resource.Info.action(Resource, :reset).public?

    domain = AikidoTest.TypedRoutesTest.Domain
    assert function_exported?(domain, :direct_increment, 2)
    refute function_exported?(domain, :direct_reset, 2)
    reference = domain.direct_start!(%{})
    domain.direct_increment!(reference, %{amount: 3})

    assert {:ok, :processed} =
             Aikido.AgentServer.call(
               reference.pid,
               AikidoTest.TypedRoutesTest.Reset.new!(%{value: 100}),
               fn _ -> {:ok, :processed} end
             )

    assert %{count: 4} = command!(Resource, :inspect, %{agent: reference})
  end

  test "slice routes use the same public default and private delivery contract" do
    slice = AikidoTest.TypedRoutesTest.PublicSlice
    resource = AikidoTest.TypedRoutesTest.PublicMounted
    domain = AikidoTest.TypedRoutesTest.Domain

    assert Ash.Resource.Info.action(slice, :increment).public?
    refute Ash.Resource.Info.action(slice, :reset).public?
    assert Ash.Resource.Info.action(resource, :increment).public?
    refute Ash.Resource.Info.action(resource, :reset)
    assert function_exported?(domain, :counter_increment, 2)
    refute function_exported?(domain, :counter_reset, 2)

    reference = domain.counter_start!(%{})
    domain.counter_increment!(reference, %{amount: "3"})

    assert {:ok, :processed} =
             Aikido.AgentServer.call(
               reference.pid,
               AikidoTest.TypedRoutesTest.Reset.new!(%{value: 100}),
               fn _ -> {:ok, :processed} end
             )

    assert %{counter: %{count: 4}} = domain.counter_inspect!(reference)
  end

  test "union routes reject a single public name rather than hiding one branch" do
    module = Module.concat(__MODULE__, "AliasedUnion#{System.unique_integer([:positive])}")

    assert_raise Spark.Error.DslError, ~r/name/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Aikido.Slice
        slice do
          name "aliased_union"
          route [AikidoTest.TypedRoutesTest.Increment, AikidoTest.TypedRoutesTest.Reset],
                AikidoTest.TypedRoutesTest.Change, name: :change_count
        end
      end
      """)
    end
  end

  test "route name overrides the public command while retaining its private reducer" do
    assert Ash.Resource.Info.action(Resource, :store).public?

    assert Ash.Resource.Info.action(Resource, :wrapped).run ==
             {AikidoTest.TypedRoutesTest.Store, []}

    refute Ash.Resource.Info.action(Resource, :wrapped).public?
    reference = command!(Resource, :start, %{})
    command!(Resource, :store, %{agent: reference, data: "named route"})
    assert %{received: "named route"} = command!(Resource, :inspect, %{agent: reference})
  end

  test "typed public declarations generate native reducers and public arguments from one schema" do
    command = Ash.Resource.Info.action(Resource, :increment)
    reducer = Ash.Resource.Info.action(Resource, :__aikido_reduce_increment)
    assert reducer.run == {AikidoTest.TypedRoutesTest.Add, []}
    assert command.description == "Increases the counter by the supplied positive amount."
    assert reducer.description == command.description
    assert reducer.returns == Aikido.Types.ActionResult
    refute reducer.public?
    assert [:state, :amount] == Enum.map(reducer.arguments, & &1.name)
    assert [:agent, :amount] == Enum.map(command.arguments, & &1.name)
    amount = Enum.find(command.arguments, &(&1.name == :amount))
    assert amount == Enum.find(reducer.arguments, &(&1.name == :amount))
    assert amount.default == 2
    assert amount.allow_nil? == false
    assert amount.constraints[:min] == 1
    assert amount.description == "Amount to add"
    assert amount.sensitive?

    reference = command!(Resource, :start, %{})
    assert %{status: :processed} = command!(Resource, :increment, %{agent: reference})
    assert %{count: 2} = command!(Resource, :inspect, %{agent: reference})
    command!(Resource, :increment, %{agent: reference, amount: "3"})
    assert %{count: 5} = command!(Resource, :inspect, %{agent: reference})
    refute Ash.ActionInput.for_action(Resource, :increment, %{agent: reference, amount: 0}).valid?
  end

  test "generated native state arguments cast and validate the owning schema" do
    input =
      Ash.ActionInput.for_action(Resource, :__aikido_reduce_increment, %{
        state: %{count: "4", received: nil},
        amount: 2
      })

    assert input.valid?, inspect(input.errors)
    assert input.arguments.state == %{count: 4, received: nil}

    invalid =
      Ash.ActionInput.for_action(Resource, :__aikido_reduce_increment, %{
        state: %{count: nil},
        amount: 2
      })

    refute invalid.valid?
  end

  test "typed field named data remains a flat field and empty schemas generate no payload argument" do
    reference = command!(Resource, :start, %{})
    command!(Resource, :store, %{agent: reference, data: false})
    assert %{received: false} = command!(Resource, :inspect, %{agent: reference})
    command!(Resource, :store, %{agent: reference, data: {:nested, %{value: 3}}})
    assert %{received: {:nested, %{value: 3}}} = command!(Resource, :inspect, %{agent: reference})

    assert [:agent] ==
             Resource
             |> Ash.Resource.Info.action(:empty)
             |> Map.fetch!(:arguments)
             |> Enum.map(& &1.name)

    command!(Resource, :empty, %{agent: reference})
    assert %{count: 1} = command!(Resource, :inspect, %{agent: reference})
  end

  test "typed lists generate one shared native union handler and preserve mounted fan-out" do
    routes = Spark.Dsl.Extension.get_entities(CounterSlice, [:slice])
    assert Enum.map(routes, & &1.type) == ["typed.increment", "typed.reset"]
    assert Enum.map(routes, & &1.action) == [{CounterSlice, :change}, {CounterSlice, :change}]

    assert Ash.Resource.Info.action(CounterSlice, :change).run ==
             {AikidoTest.TypedRoutesTest.Change, []}

    assert Ash.Resource.Info.action(CounterSlice, :change).description == nil

    assert Ash.Resource.Info.action(AikidoTest.TypedRoutesTest.ObserverSlice, :count).description ==
             nil

    data =
      Enum.find(Ash.Resource.Info.action(CounterSlice, :change).arguments, &(&1.name == :data))

    assert data.type == Ash.Type.Union
    assert Keyword.keys(data.constraints[:types]) == [:increment, :reset]

    reference = command!(Mounted, :start, %{})
    baseline = command!(Mounted, :inspect, %{agent: reference}).observer.count
    command!(Mounted, :increment, %{agent: reference, amount: "4"})

    assert %{first: %{count: 4}, second: %{count: 4}, observer: %{count: first_count}} =
             command!(Mounted, :inspect, %{agent: reference})

    assert first_count == baseline + 1
    command!(Mounted, :reset, %{agent: reference, value: "7"})

    assert %{first: %{count: 7}, second: %{count: 7}, observer: %{count: second_count}} =
             command!(Mounted, :inspect, %{agent: reference})

    assert second_count == baseline + 2
    refute Ash.Resource.Info.action(Mounted, :count)

    assert {:ok, _} =
             Aikido.AgentServer.call(
               reference.pid,
               Aikido.Signal.new!("other.event", {:arbitrary, false}),
               fn _ -> {:ok, :processed} end
             )

    assert %{observer: %{count: third_count}} = command!(Mounted, :inspect, %{agent: reference})
    assert third_count == baseline + 3
  end

  test "native signal payload types validate, cast and evaluate defaults only once" do
    definition = AikidoTest.TypedRoutesTest.Defaulted
    assert Ash.Type.NewType.new_type?(definition)
    assert {:ok, %{mfa: 3, function: false}} = Ash.Type.cast_input(definition, %{}, [])
    assert_received {:payload_default, :mfa}
    assert_received {:payload_default, :function}
    refute_received {:payload_default, _}

    assert {:ok, signal} = definition.new(%{})
    assert signal.data == %{mfa: 3, function: false}
    assert_received {:payload_default, :mfa}
    assert_received {:payload_default, :function}
    refute_received {:payload_default, _}

    assert {:ok, %{mfa: 4, function: nil}} =
             Ash.Type.cast_input(definition, %{"mfa" => "4", "function" => nil}, [])

    refute_received {:payload_default, _}
    assert {:error, _} = Ash.Type.cast_input(definition, %{mfa: 0, function: false}, [])
    assert {:error, _} = Ash.Type.apply_constraints(definition, %{mfa: 0, function: false}, [])
    refute_received {:payload_default, _}
  end

  test "list routes select the native union branch by signal type even for overlapping shapes" do
    reference = command!(Resource, :start, %{})

    for {type, branch, marker, payload, expected} <- [
          {"typed.first", :first, "first", %{}, %{data: false, marker: "first"}},
          {"typed.second", :second, "second", %{data: nil}, %{data: nil, marker: "second"}},
          {"typed.second", :second, "second", %{data: false}, %{data: false, marker: "second"}}
        ] do
      signal = Aikido.Signal.new!(type, payload)

      assert {:ok, _} =
               Aikido.AgentServer.call(reference.pid, signal, fn _ -> {:ok, :processed} end)

      assert %{
               received: %{union: %Ash.Union{type: ^branch, value: ^expected}, original: ^payload}
             } = command!(Resource, :inspect, %{agent: reference})

      assert expected.marker == marker
    end
  end

  test "slice state arguments preserve their resource struct and validate native fields" do
    state = struct(CounterSlice, count: "3")

    input =
      Ash.ActionInput.for_action(CounterSlice, :change, %{
        state: state,
        data: %Ash.Union{type: :increment, value: %{amount: "2"}}
      })

    assert input.valid?, inspect(input.errors)
    assert %CounterSlice{count: 3} = input.arguments.state
    assert %Ash.Union{type: :increment, value: %{amount: 2}} = input.arguments.data

    invalid =
      Ash.ActionInput.for_action(CounterSlice, :change, %{
        state: struct(CounterSlice, count: nil),
        data: %Ash.Union{type: :increment, value: %{amount: 2}}
      })

    refute invalid.valid?
  end

  test "invalid typed signal references produce structured DSL errors" do
    for definition <- ["String", "AikidoTest.TypedRoutesTest.DoesNotExist"] do
      module = "AikidoTest.TypedRoutesTest.Invalid#{System.unique_integer([:positive])}"

      assert_raise Spark.Error.DslError, ~r/must use Aikido.Signal/, fn ->
        Code.compile_string("""
        defmodule #{module} do
          use Aikido.Agent
          agent do
            name "invalid"
            route #{definition}, AikidoTest.TypedRoutesTest.Add, name: :bad
          end
        end
        """)
      end
    end
  end

  test "native implementation references are verified after owning resources compile" do
    module =
      "AikidoTest.TypedRoutesTest.InvalidActionTarget#{System.unique_integer([:positive])}"

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{module} do
          use Aikido.Agent
          agent do
            name "invalid_action_target"
            route AikidoTest.TypedRoutesTest.Increment, String, name: :bad
          end
        end
        """)
      end)

    assert output =~ "native Ash action implementations"
  end

  defp command!(resource, action, arguments) do
    resource |> Ash.ActionInput.for_action(action, arguments) |> Ash.run_action!()
  end
end
