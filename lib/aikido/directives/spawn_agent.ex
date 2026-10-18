defmodule Aikido.Directives.SpawnAgent do
  @moduledoc """
  Spawn a child agent with parent-child hierarchy tracking.

  Unlike `Spawn`, this directive specifically spawns another Aikido agent
  and sets up the logical parent-child relationship:

  - Child's parent reference points to the spawning agent
  - Parent monitors the child process
  - Parent tracks child in its children map by tag
  - Child exit signals are delivered to parent as `aikido.agent.child.exit`
  - Child sees `ctx.parent` (a `%ParentRef{}`) on every signal while attached

  The logical relationship is independent from OTP supervisory ancestry. If
  the child later becomes orphaned, `ctx.parent` becomes `nil` and the child
  must be explicitly reattached with `AdoptChild`. The active logical
  binding is saved in the child's DurableServer snapshot, so recovery restores
  the current relationship instead of stale startup metadata.

  ## Fields

  - `agent` - Agent module (atom) or pre-built agent struct to spawn
  - `tag` - Tag for tracking this child (used as key in children map)
  - `opts` - Additional options passed to child AgentServer. Supports standard
    child startup options like `:id`, `:initial_state`, and `:on_parent_death`,
    but not Durable lifecycle options like `:pool`, or `:pool_key`
  - `meta` - Metadata to pass to child via parent reference
  - `restart` - Restart policy for the child under supervision (default: `:transient`)

  ## Examples

      # Spawn a worker agent
      %SpawnAgent{agent: MyWorkerAgent, tag: :worker_1}

      # Spawn with custom ID and initial state
      %SpawnAgent{
        agent: MyWorkerAgent,
        tag: :processor,
        opts: %{id: "custom-id", initial_state: %{batch_size: 100}}
      }

      # Spawn with metadata for the child
      %SpawnAgent{
        agent: MyWorkerAgent,
        tag: :handler,
        meta: %{assigned_topic: "events.user"}
      }

      # Override restart behavior for long-lived workers
      %SpawnAgent{
        agent: MyWorkerAgent,
        tag: :supervised,
        restart: :permanent
      }
  """

  use Aikido.Directive

  typed_struct do
    field :agent, :term,
      allow_nil?: false,
      description: "Agent module (atom) or pre-built agent struct"

    field :tag, :term, allow_nil?: false, description: "Tag for tracking this child"

    field :opts, :map,
      allow_nil?: false,
      default: %{},
      description: "Options for child AgentServer"

    field :meta, :map, allow_nil?: false, default: %{}, description: "Metadata to pass to child"

    field :restart, :atom,
      allow_nil?: false,
      default: :transient,
      constraints: [one_of: [:permanent, :transient, :temporary]],
      description: "Restart policy for the child"
  end

  @doc """
  Pure I/O directive: starts the child through DurableServer with its logical
  parent binding. The
  child's own `notify_parent_of_startup/1` then casts
  `aikido.agent.child.started` back to this agent, where
  `maybe_track_child_started/2` records the `%ChildInfo{}` and creates
  the parent-side monitor.

  Async window: between the directive returning and the natural
  `child.started` arriving, `state.children[tag]` is `nil`. Tests should
  use `AgentServer.await_child/3` rather than peeking at `state.children`
  immediately.
  """

  alias Aikido.Directives

  require Logger

  @reserved_child_opts [:agent, :agent_module, :id, :aikido, :parent, :partition]

  @impl true
  def exec(
        %{agent: agent, tag: tag, opts: opts, meta: meta, restart: restart},
        _input_signal,
        state
      ) do
    with :ok <- Directives.validate_restart_policy(restart),
         :ok <- Directives.validate_spawn_agent_opts(opts) do
      spawn_child(state, agent, tag, opts, meta, restart)
    else
      {:error, reason} ->
        Logger.error("AgentServer #{state.id} failed to spawn child: #{reason}")
        :ok
    end
  end

  defp resolve_agent_module(agent) when is_atom(agent), do: agent
  defp resolve_agent_module(%{__struct__: module}), do: module
  defp resolve_agent_module(_), do: nil

  defp spawn_child(state, agent, tag, opts, meta, restart) do
    child_id = opts[:id] || "#{state.id}/#{tag}"
    child_partition = Map.get(opts, :partition, state.partition)
    agent_module = resolve_agent_module(agent)

    parent_ref = %{
      pid: self(),
      id: state.id,
      partition: state.partition,
      tag: tag,
      meta: meta
    }

    child_opts =
      opts
      |> Map.drop(@reserved_child_opts)
      |> Map.put(:agent_module, agent_module)
      |> Map.put(:id, child_id)
      |> Map.put(:partition, child_partition)
      |> Map.put(:parent, parent_ref)
      |> maybe_put_aikido(state.aikido)
      |> Map.to_list()

    case Aikido.start_agent(
           state.aikido || Aikido.Default,
           agent_module,
           Keyword.put(child_opts, :restart, restart)
         ) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to spawn child #{child_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_put_aikido(opts, nil), do: opts
  defp maybe_put_aikido(opts, aikido), do: Map.put(opts, :aikido, aikido)
end
