defmodule Aikido.Ash.Team do
  @moduledoc """
  Topology and coordination extension for process-backed Ash agent resources.

  Declare eager or lazy `member`s and reusable `worker` templates. Generated
  domain actions start/reconcile a topology, add/ensure/stop/remove members,
  send/broadcast signals, and assign tracked tasks. Lifecycle changes are
  signal chains; Ash lifecycle actions wait for completion in the external caller.

      team do
        member :lead, MyApp.Planner
        member :reviewer, MyApp.Reviewer, activation: :lazy, depends_on: [:lead]
        worker :researcher, MyApp.Researcher, max_members: 4
      end

  The generic `start` action accepts `topology` to replace the DSL graph at
  initial activation. Omitted or nil uses the declared graph; `%{}` starts empty.
  Nested team graphs go in a node's `initial_state.topology`. Restored durable
  identities preserve their saved graph; use `configure_topology` to change it.

  A team resource may itself be a member. `owner` establishes parent-child
  lifetime and `depends_on` determines activation order. Every member uses the
  same Aikido instance. Desired topology and runtime membership are separate;
  failed activation remains observable and can be reconciled.
  """
  defmodule Member do
    @moduledoc false
    defstruct [
      :name,
      :resource,
      :owner,
      initial_state: %{},
      activation: :eager,
      depends_on: [],
      __spark_metadata__: nil
    ]
  end

  defmodule Worker do
    @moduledoc false
    defstruct [:name, :resource, max_members: 8, initial_state: %{}, __spark_metadata__: nil]
  end

  @member %Spark.Dsl.Entity{
    name: :member,
    target: Member,
    args: [:name, :resource],
    schema: [
      name: [type: :atom, required: true],
      resource: [type: :module, required: true],
      initial_state: [type: :map, default: %{}],
      activation: [type: {:in, [:eager, :lazy]}, default: :eager],
      owner: [type: :atom],
      depends_on: [type: {:list, :atom}, default: []]
    ]
  }
  @worker %Spark.Dsl.Entity{
    name: :worker,
    target: Worker,
    args: [:name, :resource],
    schema: [
      name: [type: :atom, required: true],
      resource: [type: :module, required: true],
      max_members: [type: :pos_integer, default: 8],
      initial_state: [type: :map, default: %{}]
    ]
  }
  @team %Spark.Dsl.Section{
    name: :team,
    entities: [@member, @worker],
    schema: [
      topology: [type: :map, default: %{}],
      inherit: [
        type: {:list, :atom},
        default: [],
        doc:
          "Own-state attributes copied to members at creation; explicit member initial values take precedence."
      ],
      max_members: [type: :pos_integer, default: 128],
      operation_timeout: [type: :pos_integer, default: 5_000]
    ]
  }
  use Spark.Dsl.Extension, sections: [@team], transformers: [Aikido.Ash.Transformers.Team]

  @doc false
  def start(resource, pid, topology, context \\ %{}) do
    signal =
      Jido.Signal.new!("aikido.ash.team.start", %{topology: topology})
      |> Aikido.SignalCtx.put_ctx(context)

    call(resource, pid, signal)
  end

  @doc false
  def call(resource, pid, signal) do
    selector = fn runtime ->
      operation = runtime.agent.state.team.operation

      cond do
        operation.id != signal.id -> :skip
        operation.status == :completed -> {:ok, :completed}
        operation.status == :failed -> {:error, operation.error}
        true -> :skip
      end
    end

    Aikido.AgentServer.call_until(pid, signal, "aikido.ash.team.**", selector,
      timeout: resource.__aikido_team_config__().timeout + 1_000
    )
  end
end
