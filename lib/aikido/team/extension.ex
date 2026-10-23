defmodule Aikido.Team.Extension do
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

  @member %Spark.Dsl.Entity{
    name: :member,
    target: Aikido.Team.Member,
    args: [:name, :resource],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      resource: [type: :module, required: true],
      initial_state: [type: :map, default: %{}],
      activation: [type: {:in, Aikido.Team.Types.Activation.values()}, default: :eager],
      owner: [type: :atom],
      depends_on: [type: {:list, :atom}, default: []]
    ]
  }
  @worker %Spark.Dsl.Entity{
    name: :worker,
    target: Aikido.Team.Worker,
    args: [:name, :resource],
    identifier: :name,
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
  use Spark.Dsl.Extension,
    sections: [@team],
    transformers: [Aikido.Team.Extension.Transformers.Build],
    verifiers: [Aikido.Team.Extension.Verifiers.Validate]

  @doc false
  def start(resource, pid, topology, context \\ %{}) do
    signal =
      Aikido.Signal.new!("aikido.ash.team.start", %{topology: topology})
      |> Aikido.Signal.put_ctx(context)

    dispatch_and_await_operation(resource, pid, signal)
  end

  @doc false
  def dispatch_and_await_operation(resource, pid, signal) do
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
      timeout: Aikido.Agent.Info.team_config(resource).timeout + 1_000
    )
    |> expose_operation_failure()
  end

  defp expose_operation_failure({:ok, _} = result), do: result

  defp expose_operation_failure({:error, reason}) do
    {:error,
     Ash.Error.Action.InvalidArgument.exception(
       field: :member,
       message: operation_failure_message(reason)
     )}
  end

  defp operation_failure_message({:member_exists, name}),
    do:
      "Member #{name} already exists. Inspect the roster and reuse it, or choose a different name."

  defp operation_failure_message({:worker_limit, template}),
    do:
      "The #{template} worker limit has been reached. Reuse an existing worker or remove an owned worker before spawning another."

  defp operation_failure_message(:member_limit),
    do:
      "The team member limit has been reached. Reuse an existing member or remove an owned member."

  defp operation_failure_message({:unknown_member, name}),
    do: "Member #{name} is not in this team. Inspect the roster and choose an existing member."

  defp operation_failure_message({:unknown_worker_template, template}),
    do: "Template #{template} is unavailable. Inspect the team's available worker templates."

  defp operation_failure_message({:invalid_member_name, name}),
    do: "Member name #{inspect(name)} is invalid. Use a nonempty name without path separators."

  defp operation_failure_message(:timeout),
    do:
      "Team activation timed out. Inspect the roster before retrying; a member may already have started."

  defp operation_failure_message(_reason),
    do:
      "The team lifecycle operation failed. Inspect member status and runtime logs before retrying; do not assume the requested member was started or stopped."
end
