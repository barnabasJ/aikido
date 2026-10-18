defmodule AikidoTest.AshTest do
  use AikidoTest.Case, async: false

  alias AikidoTest.AshFixtures.{Counter, Domain}

  setup do
    start_supervised!({Aikido, name: AikidoTest.AshFixtures.Instance})
    :ok
  end

  test "generic commands accept IDs and PIDs and return compact receipts" do
    assert function_exported?(Domain, :counter_start, 1)
    assert function_exported?(Domain, :counter_add, 2)
    refute function_exported?(Domain, :start_counter, 1)
    refute function_exported?(Domain, :add_counter, 2)

    for resource <- [Counter, AikidoTest.AshFixtures.Team] do
      assert Enum.all?(Ash.Resource.Info.actions(resource), &(&1.type == :action))
    end

    assert {:ok, reference} = Domain.counter_start(%{id: "receipt", count: 2})
    assert Map.keys(reference) |> Enum.sort() == [:id, :pid, :resource]
    assert reference.resource == Counter
    assert is_pid(reference.pid)
    assert {:ok, receipt} = Domain.counter_add(reference.id, %{amount: "3"})
    assert receipt.status == :processed
    assert is_binary(receipt.signal_id)
    refute Map.has_key?(receipt, :count)
    assert {:ok, %{count: 5}} = Domain.counter_inspect(receipt, %{fields: [:count]})
    assert {:ok, next} = Domain.counter_add(reference.pid, %{amount: 1})
    assert next.id == reference.id
    assert next.signal_id != receipt.signal_id
    assert {:ok, %{count: 6}} = Domain.counter_inspect(reference.id, %{fields: [:count]})
    assert {:error, _} = Domain.composed_increment(reference.pid, %{})
    assert {:error, _} = Domain.counter_add(123, %{amount: 1})
    assert {:ok, %{id: "receipt", status: :stopped}} = Domain.counter_stop(reference.id)
    assert {:error, _} = Domain.counter_inspect(reference.id)
  end

  test "agent extension leaves the native data layer independent of process actions" do
    resource = AikidoTest.AshFixtures.GeneratedCounter
    assert Ash.DataLayer.data_layer(Counter) == Ash.DataLayer.Simple
    assert Ash.DataLayer.data_layer(resource) == Ash.DataLayer.Ets
    refute function_exported?(Aikido.Ash.Agent, :can?, 2)
    refute function_exported?(Aikido.Ash.Agent, :resource_to_query, 2)

    reference = Domain.generated_counter_start!(%{id: "custom-layer", count: 3})
    assert {:ok, _} = Domain.generated_counter_add(reference.id, %{amount: 2})

    assert [%{id: "custom-layer", count: 5}] =
             Domain.generated_counter_list!(%{filter: [count: 5]})

    assert {:ok, %{status: :stopped}} = Domain.generated_counter_stop(reference.id)
  end

  test "schema declarations become real Ash attributes" do
    count = Ash.Resource.Info.attribute(Counter, :count)
    assert count.type == Ash.Type.Integer
    assert count.default == 0
    assert count.allow_nil? == false
    assert count.public?
    refute Ash.Resource.Info.attribute(Counter, :state)

    assert {:ok, counter} =
             snapshot_result(Domain.counter_start(%{id: "attribute-cast", count: "4"}))

    assert counter.count == 4
    assert {:ok, %{count: 0}} = snapshot_result(Domain.counter_start(%{count: nil}))
    assert {:error, _} = snapshot_result(Domain.counter_start(%{count: "invalid"}))
    assert [%Counter{count: 4}] = Domain.counter_list!(%{filter: [count: 4]})
  end

  test "signal targets generate typed Ash update arguments without an actions block" do
    resource = AikidoTest.AshFixtures.GeneratedCounter
    action = Ash.Resource.Info.action(resource, :add)

    assert [
             %{
               name: :amount,
               type: Ash.Type.Integer,
               allow_nil?: false,
               default: 2,
               description: "Amount to add",
               constraints: constraints
             }
           ] = Enum.reject(action.arguments, &(&1.name == :agent))

    assert constraints[:min] == 1
    record = snapshot_result(Aikido.Ash.start!(resource))

    assert {:ok, %{count: 3} = record} =
             snapshot_result(Aikido.Ash.command(record, %{amount: "3"}, action: :add))

    assert {:ok, %{count: 5} = record} =
             snapshot_result(Aikido.Ash.command(record, %{}, action: :add))

    assert {:error, %Ash.Error.Invalid{}} =
             snapshot_result(Aikido.Ash.command(record, %{amount: 0}, action: :add))

    assert {:ok, %{count: 7}} =
             snapshot_result(Aikido.Ash.command(record, %{amount: nil}, action: :add))

    assert {:ok, %{count: 11}} =
             snapshot_result(
               Aikido.Ash.command(record, %{data: %{amount: "4"}}, action: :with_data)
             )

    assert {:ok, %{status: :stopped}} = Aikido.Ash.stop(record)
  end

  test "resource agents reuse their attributes without a generated schema resource" do
    runtime = Counter.__aikido_runtime__()
    schema = Spark.Dsl.Extension.get_opt(runtime, [:agent], :schema)
    assert is_list(schema)
    assert schema[:count][:type] == Ash.Resource.Info.attribute(Counter, :count).type
    refute Keyword.has_key?(schema[:count], :default)
    assert {:ok, record} = snapshot_result(Domain.counter_start(%{id: "native-default"}))
    assert record.count == 0

    assert {:ok, updated} =
             snapshot_result(Domain.counter_increment(record, %{data: %{amount: 2}}))

    assert updated.count == 2
  end

  test "the default runtime needs no instance option" do
    start_supervised!(Aikido)

    assert {:ok, record} =
             snapshot_result(
               Aikido.Ash.start(AikidoTest.AshFixtures.DefaultCounter, %{count: "5"})
             )

    assert record.count == 5
    assert record.origin == "local"

    assert {:error, _} =
             snapshot_result(
               Aikido.Ash.start(AikidoTest.AshFixtures.DefaultCounter, %{origin: "override"})
             )

    assert is_pid(Aikido.whereis(Aikido.Default, record.id))

    assert {:error, _} =
             snapshot_result(
               Aikido.Ash.start(AikidoTest.AshFixtures.DefaultCounter, %{count: -1})
             )

    assert {:ok, %{status: :stopped}} = Aikido.Ash.stop(record)
  end

  test "domain interfaces drive the complete process lifecycle" do
    assert {:ok, counter} = snapshot_result(Domain.counter_start(%{id: "counter", count: 4}))
    assert counter.count == 4

    assert {:ok, updated} =
             snapshot_result(Domain.counter_increment(counter, %{data: %{amount: 3}}))

    assert updated.count == 7
    assert {:ok, [read]} = Domain.counter_list()
    assert read.count == 7
    pid = Aikido.whereis(AikidoTest.AshFixtures.Instance, "counter")
    ref = Process.monitor(pid)
    assert {:ok, %{status: :stopped}} = Domain.counter_stop(updated)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert {:ok, []} = Domain.counter_list()
  end

  test "read filters, sorts, limits and offsets use live snapshots" do
    for id <- ["a", "b", "c"] do
      assert {:ok, _} = snapshot_result(Domain.counter_start(%{id: id}))
    end

    assert {:ok, [%Counter{id: "a"}]} =
             Domain.counter_list(%{
               filter: [id: [not_eq: "b"]],
               sort: [id: :desc],
               offset: 1,
               limit: 1
             })
  end

  test "embedded Ash slice actions apply state through the signal pipeline" do
    assert {:ok, composed} = snapshot_result(Domain.composed_start(%{id: "composed"}))
    assert composed.counter.count == 0

    assert {:ok, updated} =
             snapshot_result(Domain.composed_increment(composed, %{data: %{amount: 5}}))

    assert updated.counter.count == 5
    assert {:ok, []} = Domain.counter_list()
    assert {:ok, [_]} = Domain.composed_list()
  end

  test "duplicate creation and missing process updates return errors" do
    assert {:ok, counter} = snapshot_result(Domain.counter_start(%{id: "duplicate"}))
    assert {:error, _} = snapshot_result(Domain.counter_start(%{id: "duplicate"}))
    assert {:ok, %{status: :stopped}} = Domain.counter_stop(counter)
    assert {:error, _} = snapshot_result(Domain.counter_increment(counter, %{data: %{amount: 1}}))
  end

  test "team creation starts members, send delivers a signal, and destroy stops children" do
    assert {:ok, team} = snapshot_result(Domain.team_start(%{id: "team"}))
    worker = team.team.members.worker
    reviewer = team.team.members.reviewer
    assert is_pid(worker)
    assert is_pid(reviewer)

    assert {:ok, %{count: 2}} =
             Aikido.AgentServer.state(worker, fn s -> {:ok, s.agent.state.state} end)

    assert {:ok, subscription} =
             Aikido.AgentServer.subscribe(
               worker,
               "counter.increment",
               fn s -> {:ok, s.agent.state.state.count} end,
               once: true
             )

    assert {:ok, _} =
             snapshot_result(
               Domain.team_send(team, %{
                 data: %{member: :worker, type: "counter.increment", payload: %{amount: 4}}
               })
             )

    assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, 6}}}
    worker_ref = Process.monitor(worker)
    reviewer_ref = Process.monitor(reviewer)
    assert {:ok, %{status: :stopped}} = Domain.team_stop(team)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    assert_receive {:DOWN, ^reviewer_ref, :process, ^reviewer, _}
  end

  test "typed Ash action arguments are validated before producing a signal" do
    assert {:ok, counter} = snapshot_result(Domain.counter_start(%{id: "typed"}))
    assert {:ok, updated} = snapshot_result(Domain.counter_add(counter, %{amount: "3"}))
    assert updated.count == 3
    assert {:error, _} = snapshot_result(Domain.counter_add(updated, %{amount: "invalid"}))
    assert {:ok, [read]} = Domain.counter_list()
    assert read.count == 3
  end

  test "an empty signal payload still executes the action" do
    assert {:ok, counter} = snapshot_result(Domain.counter_start(%{id: "empty"}))
    assert {:ok, updated} = snapshot_result(Domain.counter_increment(counter, %{}))
    assert updated.count == 1
    assert {:ok, updated} = snapshot_result(Domain.counter_increment(updated, %{}))
    assert updated.count == 2
  end

  test "Ash policies authorize creation before a process starts" do
    assert {:error, %Ash.Error.Forbidden{}} = Domain.protected_start(%{id: "protected"})
    assert Aikido.whereis(AikidoTest.AshFixtures.Instance, "protected") == nil
    assert {:ok, _} = Domain.protected_start(%{id: "protected"}, actor: %{id: "user"})
    assert is_pid(Aikido.whereis(AikidoTest.AshFixtures.Instance, "protected"))
  end

  test "slice subscriptions and schedules retain their runtime declarations" do
    slice = AikidoTest.AshFixtures.CounterSlice.AikidoSlice

    assert [{Aikido.Sensors.Heartbeat, %{interval: 3_600_000}}] =
             Aikido.Dsl.Slice.Info.subscriptions(slice)

    assert [{"0 0 1 1 *", AikidoTest.AshFixtures.CounterSlice.Actions.Tick, options}] =
             Aikido.Dsl.Slice.Info.schedules(slice)

    assert options[:data] == %{amount: 1}
  end

  test "scheduled-only Ash actions mutate their mounted slice" do
    runtime = AikidoTest.AshFixtures.Composed.__aikido_runtime__()
    agent = runtime.new()

    signal =
      Jido.Signal.new!("aikido.ash.schedule.ash_counter_slice.tick", %{amount: 4},
        source: "/test"
      )

    assert {:ok, updated, []} =
             runtime.cmd(
               agent,
               {AikidoTest.AshFixtures.CounterSlice.Actions.Tick, %{amount: 4}},
               input_signal: signal
             )

    assert updated.state.counter.count == 4
    assert updated.state.state == %{}
    assert agent.state.counter.count == 0
  end

  test "Ash slice action adapters preserve pure state transitions" do
    signal = Jido.Signal.new!("slice.increment", %{amount: 3}, source: "/test")
    state = %{count: 2}

    assert {:ok, %{count: 5}, []} =
             Aikido.Ash.Slice.run(
               AikidoTest.AshFixtures.CounterSlice,
               :increment,
               signal,
               state,
               %{}
             )

    assert state == %{count: 2}
  end

  test "invalid team members return an error without delivering a signal" do
    assert {:ok, team} = snapshot_result(Domain.team_start(%{id: "invalid-member"}))

    assert {:error, _} =
             snapshot_result(
               Domain.team_send(team, %{data: %{member: :unknown, type: "counter.increment"}})
             )

    assert {:ok, %{status: :stopped}} = Domain.team_stop(team)
  end

  test "colliding state paths fail at compile time" do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise Spark.Error.DslError, ~r/paths must be unique/, fn ->
        defmodule DuplicatePaths do
          use Ash.Resource, extensions: [Aikido.Ash.Agent]

          agent do
            name "duplicate_paths"
            instance(AikidoTest.AshFixtures.Instance)
            slice(:state, AikidoTest.AshFixtures.CounterSlice)
          end
        end
      end
    end)
  end

  test "signal declarations require a positional target" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule AikidoTest.MissingSignalTarget do
            use Ash.Resource, extensions: [Aikido.Ash.Agent]

            agent do
              name "unrouted"
              signal :missing, "missing.route"
            end
          end
          """)
        end
      end)

    assert output =~ "signal/2"
  end

  test "mounted slices expose public actions once without agent signal declarations" do
    resource = AikidoTest.AshFixtures.Composed

    [signal] =
      Enum.filter(
        Spark.Dsl.Extension.get_entities(resource, [:agent]),
        &match?(%Aikido.Ash.Agent.Signal{}, &1)
      )

    assert signal.name == :increment
    assert signal.target == AikidoTest.AshFixtures.CounterSlice.Actions.Increment
    refute Ash.Resource.Info.action(resource, :internal)
    refute Ash.Resource.Info.action(resource, :tick)
    refute function_exported?(Domain, :composed_internal, 1)
    assert Aikido.Dsl.Agent.Info.signal_routes(resource.__aikido_runtime__()) == []

    assert Aikido.Dsl.Agent.Info.slice_paths_for_action(resource.__aikido_runtime__())[
             signal.target
           ] ==
             [:counter]

    reference = Domain.composed_start!(%{})
    assert {:ok, _} = Domain.composed_increment(reference.id, %{data: %{amount: 2}})
    assert %{counter: %{count: 2}} = Domain.composed_inspect!(reference.id)
  end

  test "duplicate domain names fail at compile time" do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise Spark.Error.DslError, ~r/names must be unique/, fn ->
        defmodule DuplicateDomain do
          use Ash.Domain, extensions: [Aikido.Ash.Domain], validate_config_inclusion?: false

          agents do
            agent(:counter, AikidoTest.AshFixtures.Counter)
            agent(:counter, AikidoTest.AshFixtures.Composed)
          end
        end
      end
    end)
  end

  # Commands return receipts; state assertions opt into a separate inspection.
  defp snapshot_result({:ok, %{resource: resource, id: id}}),
    do: Aikido.Ash.inspect(resource, id)

  defp snapshot_result({:error, _} = error), do: error

  defp snapshot_result(%{resource: resource, id: id}),
    do: Aikido.Ash.inspect!(resource, id)
end
