defmodule AikidoTest.AshFixtures do
  defmodule Increment do
    use Aikido.Action

    action do
      name("ash_increment")

      schema do
      end
    end

    def run(signal, state, _opts, _context) do
      {:ok, %{count: state.count + Map.get(signal.data, :amount, 1)}, []}
    end
  end

  defmodule GeneratedIncrement do
    use Aikido.Action

    action do
      name "generated_increment"

      schema do
        attribute :amount, :integer,
          allow_nil?: false,
          default: 2,
          constraints: [min: 1],
          description: "Amount to add"
      end
    end

    def run(signal, state, _opts, _context),
      do: {:ok, %{state | count: state.count + signal.data.amount}, []}
  end

  defmodule DataIncrement do
    use Aikido.Action

    action do
      name "data_increment"

      schema do
        attribute :data, :map,
          allow_nil?: false,
          constraints: [fields: [amount: [type: :integer, allow_nil?: false]]]
      end
    end

    def run(signal, state, _opts, _context),
      do: {:ok, %{state | count: state.count + signal.data.data.amount}, []}
  end

  defmodule GeneratedCounter do
    use Ash.Resource,
      domain: AikidoTest.AshFixtures.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [Aikido.Ash.Agent]

    agent do
      name "generated_counter"
      instance AikidoTest.AshFixtures.Instance

      schema do
        attribute :count, :integer, allow_nil?: false, default: 0, public?: true
      end

      signal :add, "generated.add", GeneratedIncrement
      signal :with_data, "generated.data", DataIncrement
    end
  end

  defmodule Counter do
    use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Ash.Agent]

    actions do
      action :add, :map do
        argument(:amount, :integer, allow_nil?: false)
      end
    end

    agent do
      name("ash_counter")
      instance(AikidoTest.AshFixtures.Instance)

      schema do
        attribute :count, :integer, allow_nil?: false, default: 0, public?: true
      end

      signal(:increment, "counter.increment", Increment)
      signal(:add, "counter.add", Increment)
    end
  end

  defmodule CounterSlice do
    use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Ash.Slice]

    attributes do
      attribute(:count, :integer, public?: true, default: 0)
    end

    actions do
      action :increment, :map do
        argument(:state, :map, allow_nil?: false)
        argument(:data, :map, allow_nil?: false)

        run(fn input, _context ->
          {:ok,
           %{
             state: %{
               count: input.arguments.state.count + Map.get(input.arguments.data, :amount, 1)
             }
           }}
        end)
      end

      action :internal, :map do
        public? false
        argument :state, :map, allow_nil?: false
        argument :data, :map, allow_nil?: false
        run fn input, _context -> {:ok, %{state: input.arguments.state}} end
      end

      action :tick, :map do
        argument(:state, :map, allow_nil?: false)
        argument(:data, :map, allow_nil?: false)

        run(fn input, _context ->
          {:ok,
           %{
             state: %{
               count: input.arguments.state.count + Map.get(input.arguments.data, :amount, 1)
             }
           }}
        end)
      end
    end

    slice do
      name("ash_counter_slice")

      route("slice.increment", :increment)
      route "slice.internal", :internal
    end

    subscriptions do
      subscription(Aikido.Sensors.Heartbeat, %{interval: 3_600_000})
    end

    schedules do
      schedule("0 0 1 1 *", :tick, data: %{amount: 1})
    end
  end

  defmodule Composed do
    use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Ash.Agent]

    agent do
      name("ash_composed")
      instance(AikidoTest.AshFixtures.Instance)
      slice(:counter, CounterSlice)
    end
  end

  defmodule Team do
    use Ash.Resource,
      domain: AikidoTest.AshFixtures.Domain,
      extensions: [Aikido.Ash.Agent, Aikido.Ash.Team]

    agent do
      name("ash_team")
      instance(AikidoTest.AshFixtures.Instance)
    end

    team do
      member(:worker, Counter, initial_state: %{count: 2})
      member(:reviewer, Composed)
    end
  end

  defmodule TaskAction do
    use Aikido.Action

    action do
      name "task_echo"

      schema do
      end
    end

    def run(signal, state, _opts, _context) do
      data = signal.data
      result = String.upcase(data.text)

      reply =
        Jido.Signal.new!("aikido.ash.team.task.completed", %{
          task_id: data.task_id,
          member: data.member,
          attempt: data.attempt,
          result: result
        })

      {:ok, %{state | result: result}, [Aikido.Directives.emit_to_pid(reply, data.reply_to)]}
    end
  end

  defmodule TaskWorker do
    use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Ash.Agent]

    agent do
      name "task_worker"
      instance AikidoTest.AshFixtures.Instance

      schema do
        attribute :result, :string, public?: true
      end

      signal :task, "harness.task", TaskAction
    end
  end

  defmodule DynamicTeam do
    use Ash.Resource,
      domain: AikidoTest.AshFixtures.Domain,
      extensions: [Aikido.Ash.Agent, Aikido.Ash.Team]

    agent do
      name "dynamic_team"
      instance AikidoTest.AshFixtures.Instance
    end

    team do
      max_members 5
      worker :counter, Counter, max_members: 2
      worker :echo, TaskWorker, max_members: 2
    end
  end

  defmodule NestedTeam do
    use Ash.Resource,
      domain: AikidoTest.AshFixtures.Domain,
      extensions: [Aikido.Ash.Agent, Aikido.Ash.Team]

    agent do
      name "nested_team"
      instance AikidoTest.AshFixtures.Instance
    end

    team do
      member :subteam, Team
      member :lazy, Counter, activation: :lazy, owner: :subteam, depends_on: [:subteam]
    end
  end

  defmodule Protected do
    use Ash.Resource,
      domain: AikidoTest.AshFixtures.Domain,
      extensions: [Aikido.Ash.Agent],
      authorizers: [Ash.Policy.Authorizer]

    agent do
      name("protected")
      instance(AikidoTest.AshFixtures.Instance)
    end

    policies do
      policy action(:start) do
        authorize_if(actor_present())
      end
    end
  end

  defmodule DefaultCounter do
    use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Ash.Agent]

    agent do
      name "default_runtime_counter"

      schema do
        attribute :count, :integer do
          default 0
          allow_nil? false
          public? true
          constraints min: 0
        end

        attribute :origin, :string, default: "local", writable?: false, public?: true
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, extensions: [Aikido.Ash.Domain], validate_config_inclusion?: false

    agents do
      agent :generated_counter, GeneratedCounter
      agent :default_counter, DefaultCounter
      agent(:counter, Counter)
      agent(:composed, Composed)
      agent(:team, Team)
      agent :dynamic, DynamicTeam
      agent :nested, NestedTeam
      agent :task_worker, TaskWorker
      agent(:protected, Protected)
    end
  end
end
