defmodule AikidoTest.AshFixtures.Increment.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    Aikido.ActionResult.new(
      state: %{count: state.count + input.arguments.amount},
      directives: []
    )
  end
end

defmodule AikidoTest.AshFixtures.GeneratedIncrement.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    Aikido.ActionResult.new(
      state: %{state | count: state.count + input.arguments.amount},
      directives: []
    )
  end
end

defmodule AikidoTest.AshFixtures.DataIncrement.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    Aikido.ActionResult.new(
      state: %{state | count: state.count + input.arguments.data.amount},
      directives: []
    )
  end
end

defmodule AikidoTest.AshFixtures.GeneratedCounter do
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

    signal :add, "generated.add", :reduce_increment
    signal :with_data, "generated.data", :reduce_data
  end

  actions do
    action :reduce_increment, Aikido.ActionResult do
      argument :state, :term

      argument :amount, :integer,
        allow_nil?: false,
        default: 2,
        constraints: [min: 1],
        description: "Amount to add"

      run {AikidoTest.AshFixtures.GeneratedIncrement.Implementation, action: :run}
    end
  end

  actions do
    action :reduce_data, Aikido.ActionResult do
      argument :state, :term

      argument :data, :map,
        allow_nil?: false,
        constraints: [fields: [amount: [type: :integer, allow_nil?: false]]]

      run {AikidoTest.AshFixtures.DataIncrement.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AshFixtures.Counter do
  use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Ash.Agent]

  agent do
    name "ash_counter"
    instance AikidoTest.AshFixtures.Instance

    schema do
      attribute :count, :integer, allow_nil?: false, default: 0, public?: true
    end

    signal :increment, "counter.increment", :reduce_increment
    signal :add, "counter.add", :reduce_increment
  end

  actions do
    action :reduce_increment, Aikido.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run {AikidoTest.AshFixtures.Increment.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AshFixtures.CounterSlice.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :increment}} = input,
        _opts,
        _context
      ) do
    Aikido.ActionResult.new(
      state: %{count: input.arguments.state.count + Map.get(input.arguments.data, :amount, 1)}
    )
  end

  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :internal}} = input,
        _opts,
        _context
      ) do
    Aikido.ActionResult.new(state: input.arguments.state)
  end

  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :tick}} = input,
        _opts,
        _context
      ) do
    Aikido.ActionResult.new(
      state: %{count: input.arguments.state.count + Map.get(input.arguments.data, :amount, 1)}
    )
  end
end

defmodule AikidoTest.AshFixtures.CounterSlice do
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Ash.Slice]

  attributes do
    attribute :count, :integer, public?: true, default: 0
  end

  actions do
    action :increment, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :data, :map, allow_nil?: false
      run AikidoTest.AshFixtures.CounterSlice.Implementation
    end

    action :internal, Aikido.ActionResult do
      public? false
      argument :state, :map, allow_nil?: false
      argument :data, :map, allow_nil?: false
      run AikidoTest.AshFixtures.CounterSlice.Implementation
    end

    action :tick, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :data, :map, allow_nil?: false
      run AikidoTest.AshFixtures.CounterSlice.Implementation
    end
  end

  slice do
    name "ash_counter_slice"
    route "slice.increment", :increment
    route "slice.internal", :internal
  end

  schedules do
    schedule "0 0 1 1 *", :tick, data: %{amount: 1}
  end
end

defmodule AikidoTest.AshFixtures.Composed do
  use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Ash.Agent]

  agent do
    name "ash_composed"
    instance AikidoTest.AshFixtures.Instance
    slice :counter, AikidoTest.AshFixtures.CounterSlice
  end
end

defmodule AikidoTest.AshFixtures.Team do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Team]

  agent do
    name "ash_team"
    instance AikidoTest.AshFixtures.Instance
  end

  team do
    member :worker, AikidoTest.AshFixtures.Counter, initial_state: %{count: 2}
    member :reviewer, AikidoTest.AshFixtures.Composed
  end
end

defmodule AikidoTest.AshFixtures.TaskAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    data = Map.delete(input.arguments, :state)
    result = String.upcase(data.text)

    reply =
      struct!(Jido.Signal,
        id: nil,
        source: "/test",
        type: "aikido.ash.team.task.completed",
        data: %{
          task_id: data.task_id,
          member: data.member,
          attempt: data.attempt,
          result: result
        }
      )

    Aikido.ActionResult.new(
      state: %{state | result: result},
      directives: [Aikido.Directives.emit_to_pid(reply, data.reply_to)]
    )
  end
end

defmodule AikidoTest.AshFixtures.TaskWorker do
  use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Ash.Agent]

  agent do
    name "task_worker"
    instance AikidoTest.AshFixtures.Instance

    schema do
      attribute :result, :string, public?: true
    end

    signal :task, "harness.task", :task_echo
  end

  actions do
    action :task_echo, Aikido.ActionResult do
      argument :state, :term
      argument :text, :string, allow_nil?: false
      argument :task_id, :string, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :attempt, :string, allow_nil?: false
      argument :reply_to, :term, allow_nil?: false
      run {AikidoTest.AshFixtures.TaskAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AshFixtures.DynamicTeam do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Team]

  agent do
    name "dynamic_team"
    instance AikidoTest.AshFixtures.Instance
  end

  team do
    max_members 5
    worker :counter, AikidoTest.AshFixtures.Counter, max_members: 2
    worker :echo, AikidoTest.AshFixtures.TaskWorker, max_members: 2
  end
end

defmodule AikidoTest.AshFixtures.NestedTeam do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Team]

  agent do
    name "nested_team"
    instance AikidoTest.AshFixtures.Instance
  end

  team do
    member :subteam, AikidoTest.AshFixtures.Team

    member :lazy, AikidoTest.AshFixtures.Counter,
      activation: :lazy,
      owner: :subteam,
      depends_on: [:subteam]
  end
end

defmodule AikidoTest.AshFixtures.Protected do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    extensions: [Aikido.Ash.Agent],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "protected"
    instance AikidoTest.AshFixtures.Instance
  end

  policies do
    policy action(:start) do
      authorize_if actor_present()
    end
  end
end

defmodule AikidoTest.AshFixtures.DefaultCounter do
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

defmodule AikidoTest.AshFixtures.Domain do
  use Ash.Domain, extensions: [Aikido.Ash.Domain], validate_config_inclusion?: false

  agents do
    agent :generated_counter, AikidoTest.AshFixtures.GeneratedCounter
    agent :default_counter, AikidoTest.AshFixtures.DefaultCounter
    agent :counter, AikidoTest.AshFixtures.Counter
    agent :composed, AikidoTest.AshFixtures.Composed
    agent :team, AikidoTest.AshFixtures.Team
    agent :dynamic, AikidoTest.AshFixtures.DynamicTeam
    agent :nested, AikidoTest.AshFixtures.NestedTeam
    agent :task_worker, AikidoTest.AshFixtures.TaskWorker
    agent :protected, AikidoTest.AshFixtures.Protected
  end
end
