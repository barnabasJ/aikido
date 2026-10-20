defmodule Aikido.Dsl.ContractRegressionsTest.Increment do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | count: state.count + input.arguments.amount})
  end
end

defmodule Aikido.Dsl.ContractRegressionsTest.RemoteSlice do
  use Aikido.Slice

  slice do
    name "remote_counter"
  end

  actions do
    action :increment, Aikido.Types.ActionResult do
      argument :state, :term, allow_nil?: false
      argument :amount, :integer, default: 1
      run Aikido.Dsl.ContractRegressionsTest.Increment
    end
  end
end

defmodule Aikido.Dsl.ContractRegressionsTest.Counter do
  use Aikido.Agent

  agent do
    name "contract_counter"
    instance Aikido.Dsl.ContractRegressionsTest.Runtime

    schema do
      attribute :count, :integer, default: 0
    end

    signal :increase, "contract.increase", :increment
    signal :increment, "contract.increment", :increment
    route "contract.internal", :increment
    route "contract.tuple", {__MODULE__, :increment}
    route "contract.remote", {Aikido.Dsl.ContractRegressionsTest.RemoteSlice, :increment}
  end

  actions do
    action :increment, Aikido.Types.ActionResult do
      argument :state, :term, allow_nil?: false
      argument :amount, :integer, default: 1
      run Aikido.Dsl.ContractRegressionsTest.Increment
    end
  end
end

defmodule Aikido.Dsl.ContractRegressionsTest.NodesTeam do
  use Aikido.Agent, extensions: [Aikido.Ash.Team]

  agent do
    name "nodes_team"
    instance Aikido.Dsl.ContractRegressionsTest.Runtime
  end

  team do
    member :nodes, Aikido.Dsl.ContractRegressionsTest.Counter
  end
end

defmodule Aikido.Dsl.ContractRegressionsTest.ScheduledSlice do
  use Aikido.Slice

  slice do
    name "scheduled_contract"

    schema do
      attribute :count, :integer, default: 0
    end
  end

  actions do
    action :tick, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :amount, :integer, default: 1
      run Aikido.Dsl.ContractRegressionsTest.Increment
    end
  end

  schedules do
    schedule "@yearly", :tick
    schedule "@monthly", :tick
  end
end

defmodule Aikido.Dsl.ContractRegressionsTest.ScheduleVariants do
  use Aikido.Slice

  slice do
    name "schedule_variants"
  end

  actions do
    action :tick, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :amount, :integer, default: 1
      run Aikido.Dsl.ContractRegressionsTest.Increment
    end
  end

  schedules do
    schedule "@yearly", :tick
    schedule "@yearly", :tick, tz: "Etc/UTC"
    schedule "@yearly", :tick, tz: ""
    schedule "@monthly", :tick
    schedule "@yearly", :tick, tz: "America/New_York"
    schedule "@yearly", :tick, data: %{amount: 2}
    schedule "@yearly", :tick, signal: "custom.tick"
  end
end

defmodule Aikido.Dsl.ContractRegressionsTest.ScheduledAgent do
  use Aikido.Agent

  agent do
    name "scheduled_contract_agent"
    instance Aikido.Dsl.ContractRegressionsTest.Runtime
    slice :clock, Aikido.Dsl.ContractRegressionsTest.ScheduledSlice
  end
end

defmodule Aikido.Dsl.ContractRegressionsTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(
      {Aikido,
       name: Aikido.Dsl.ContractRegressionsTest.Runtime,
       durable: AikidoTest.Case.durable_options()}
    )

    :ok
  end

  test "local alternate routes and earlier shared signals keep the reducer alias" do
    resource = Aikido.Dsl.ContractRegressionsTest.Counter
    routes = Aikido.Dsl.Agent.Info.signal_routes(resource)
    targets = for {type, target, _priority} <- routes, type != "contract.remote", do: target

    assert {"contract.remote", {Aikido.Dsl.ContractRegressionsTest.RemoteSlice, :increment}, 0} in routes

    assert [target] = Enum.uniq(targets)
    assert {^resource, action} = target
    assert Ash.Resource.Info.action(resource, action).returns == Aikido.Types.ActionResult

    reference = resource |> Ash.ActionInput.for_action(:start, %{}) |> Ash.run_action!()

    for public <- [:increase, :increment] do
      resource
      |> Ash.ActionInput.for_action(public, %{agent: reference, amount: "2"})
      |> Ash.run_action!()
    end

    for type <- ["contract.internal", "contract.tuple"] do
      assert {:ok, _} =
               Aikido.AgentServer.call(
                 reference.pid,
                 Jido.Signal.new!(type, %{amount: "3"}),
                 fn s ->
                   {:ok, s.agent.state.state.count}
                 end
               )
    end

    assert {:ok, 14} =
             Aikido.AgentServer.call(
               reference.pid,
               Jido.Signal.new!("contract.remote", %{amount: "4"}),
               fn s ->
                 {:ok, s.agent.state.state.count}
               end
             )

    assert {:ok, 14} = Aikido.AgentServer.state(reference.pid, &{:ok, &1.agent.state.state.count})
  end

  test "nodes is an ordinary bare topology member and a running DSL team member" do
    resource = Aikido.Dsl.ContractRegressionsTest.Counter

    assert {:ok, topology} =
             Aikido.Ash.Team.Topology.build(
               %{nodes: %{resource: resource}, sibling: %{resource: resource}},
               Aikido.Dsl.ContractRegressionsTest.Runtime
             )

    assert Map.keys(topology.nodes) |> Enum.sort() == [:nodes, :sibling]

    reference =
      Aikido.Dsl.ContractRegressionsTest.NodesTeam
      |> Ash.ActionInput.for_action(:start, %{})
      |> Ash.run_action!()

    assert {:ok, members} =
             Aikido.AgentServer.state(reference.pid, &{:ok, &1.agent.state.team.members})

    assert is_pid(members.nodes)
  end

  test "distinct schedules for one slice action own separate jobs and dispatch once per occurrence" do
    resource = Aikido.Dsl.ContractRegressionsTest.ScheduledAgent
    specs = Aikido.Dsl.Agent.Info.schedules(resource)
    assert length(specs) == 2
    assert length(Enum.uniq_by(specs, & &1.job_id)) == 2

    routes = Aikido.Dsl.Agent.Info.routes(resource)
    assert [{"clock.__schedule__.tick", _, _}] = routes
    reference = resource |> Ash.ActionInput.for_action(:start, %{}) |> Ash.run_action!()
    assert {:ok, jobs} = Aikido.AgentServer.state(reference.pid, &{:ok, &1.cron_jobs})
    assert map_size(jobs) == 2

    for {job, expected} <- Enum.with_index(Map.values(jobs), 1) do
      {:ok, ref} =
        Aikido.AgentServer.subscribe(
          reference.pid,
          "clock.__schedule__.tick",
          fn s ->
            {:ok, s.agent.state.clock.count}
          end,
          once: true
        )

      send(job, :tick)
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, ^expected}}}
    end

    assert {:ok, 2} = Aikido.AgentServer.state(reference.pid, &{:ok, &1.agent.state.clock.count})
  end

  test "slice schedule identity includes every normalized behavior field" do
    target = {Aikido.Dsl.ContractRegressionsTest.ScheduledSlice, :tick}
    instance = %Aikido.Slice.Instance{module: elem(target, 0), path: :clock}
    [base | _] = Aikido.Slice.Schedules.expand_schedules(instance)

    assert base.job_id ==
             {:slice_schedule, :clock, {target, "@yearly", "Etc/UTC", base.signal_type, %{}}}

    variants =
      Aikido.Slice.Schedules.expand_schedules(%Aikido.Slice.Instance{
        module: Aikido.Dsl.ContractRegressionsTest.ScheduleVariants,
        path: :clock
      })

    [implicit, explicit, empty | distinct] = variants
    assert implicit.job_id == explicit.job_id
    assert implicit.job_id == empty.job_id
    assert length(Enum.uniq_by([implicit | distinct], & &1.job_id)) == 5
    assert Enum.any?(variants, &(&1.data == %{amount: 2}))
    assert Enum.any?(variants, &(&1.signal_type == "clock.custom.tick"))
  end

  test "agent schedules reject collisions between defaults and explicit IDs" do
    for declarations <- [
          "schedule \"@yearly\", \"tick\"\nschedule \"@monthly\", \"tick\"",
          "schedule \"@yearly\", \"first\", job_id: :same\nschedule \"@monthly\", \"second\", job_id: :same",
          "schedule \"@yearly\", \"tick\"\nschedule \"@monthly\", \"second\", job_id: \"tick\""
        ] do
      module = Module.concat(__MODULE__, "InvalidSchedule#{System.unique_integer([:positive])}")

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule #{inspect(module)} do
            use Aikido.Agent
            agent do
              name "invalid_schedules"
            end
            schedules do
              #{declarations}
            end
          end
          """)
        end)

      assert output =~ "Agent schedules require unique job IDs"
    end
  end

  test "agent schedules retain distinct explicit IDs for the same signal" do
    module = Module.concat(__MODULE__, "DistinctSchedule#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Aikido.Agent
      agent do
        name "distinct_schedules"
        instance Aikido.Dsl.ContractRegressionsTest.Runtime
      end
      schedules do
        schedule "@yearly", "tick", job_id: :first
        schedule "@monthly", "tick", job_id: :second
      end
    end
    """)

    assert Enum.map(Aikido.Dsl.Agent.Info.schedules(module), & &1.job_id) == [
             {:agent_schedule, "distinct_schedules", :first},
             {:agent_schedule, "distinct_schedules", :second}
           ]

    reference = module |> Ash.ActionInput.for_action(:start, %{}) |> Ash.run_action!()
    assert {:ok, jobs} = Aikido.AgentServer.state(reference.pid, &{:ok, &1.cron_jobs})
    assert map_size(jobs) == 2
    assert Enum.all?(Map.values(jobs), &Process.alive?/1)
  end
end
