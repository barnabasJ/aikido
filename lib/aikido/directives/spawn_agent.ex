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

  - `agent` - Agent Ash resource module to spawn
  - `tag` - Tag for tracking this child (used as key in children map)
  - `opts` - Additional options passed to child AgentServer. Supports standard
    child startup options like `:id`, `:initial_state`, and `:on_parent_death`,
    but not Durable lifecycle options like `:durable_server` or `:durable_key`
  - `meta` - Metadata to pass to child via parent reference
  - `restart?` - Automatically recover the child after a crash (default: `true`)

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
        restart?: true
      }
  """

  use Aikido.Directive

  typed_struct do
    field :agent, :module do
      allow_nil? false
      description "Agent Ash resource module"
    end

    field :tag, :term do
      allow_nil? false
      description "Tag for tracking this child"
    end

    field :opts, :map do
      allow_nil? false
      default %{}
      description "Options for child AgentServer"
    end

    field :meta, :map do
      allow_nil? false
      default %{}
      description "Metadata to pass to child"
    end

    field :restart?, :boolean do
      allow_nil? false
      default true
      description "Let DurableServer automatically recover the child after a crash"
    end
  end

  @doc """
  Pure I/O directive: starts the child in supervised work through DurableServer
  with its logical parent binding. The
  child's own `notify_parent_of_startup/1` then casts
  `aikido.agent.child.started` back to this agent, where
  `maybe_track_child_started/2` records the `%ChildInfo{}` and creates
  the parent-side monitor.

  Async window: between the directive returning and the natural
  `child.started` arriving, `state.children[tag]` is `nil`. Tests should
  use `AgentServer.await_child/3` rather than peeking at `state.children`
  immediately.
  """

  require Logger

  @reserved_child_opts [:agent, :agent_module, :id, :aikido, :parent, :partition]

  @impl true
  def exec(%{agent: agent, tag: tag, opts: opts, meta: meta, restart?: restart?}, signal, state) do
    parent_pid = self()
    scope = Aikido.Signal.ctx(signal)

    opts =
      Map.put(
        opts,
        :initialization_options,
        Ash.Scope.to_opts(scope, context: Map.get(scope, :context) || %{})
      )

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        spawn_child(state, parent_pid, agent, tag, opts, meta, restart?)
        {:signals, []}
      end
    }

    case Aikido.Directives.AsyncTask.start(task, signal, state) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("Failed to start agent spawn task: #{inspect(reason)}")
    end

    :ok
  end

  defp spawn_child(state, parent_pid, agent, tag, opts, meta, restart?) do
    child_id = opts[:id] || "#{state.id}/#{tag_component(tag)}"
    child_partition = Map.get(opts, :partition, state.partition)

    parent_ref = %{
      pid: parent_pid,
      id: state.id,
      partition: state.partition,
      tag: tag,
      meta: meta
    }

    child_opts = child_options(opts, state, parent_ref, agent, child_id, child_partition)

    case Aikido.Durable.start(
           Aikido.durable_supervisor_name(state.aikido),
           child_id,
           agent: agent,
           initial_state: Keyword.get(child_opts, :initial_state, %{}),
           partition: child_partition,
           agent_opts: child_opts,
           permanent: restart?
         ) do
      {:ok, pid} ->
        if !Process.alive?(parent_pid) do
          GenServer.cast(
            pid,
            {:ensure_initial_parent, Aikido.AgentServer.ParentRef.new!(parent_ref)}
          )
        end

        :ok

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to spawn child #{child_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp child_options(opts, state, parent_ref, agent, child_id, child_partition) do
    opts
    |> Map.drop(@reserved_child_opts)
    |> Map.put(:agent_module, agent)
    |> Map.put(:id, child_id)
    |> Map.put(:partition, child_partition)
    |> Map.put(:parent, parent_ref)
    |> Map.put(:aikido, state.aikido)
    |> Map.to_list()
  end

  defp tag_component(tag) do
    to_string(tag)
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] ->
      encoded =
        tag |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

      "term:" <> encoded
  end
end
