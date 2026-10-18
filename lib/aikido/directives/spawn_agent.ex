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
  binding is mirrored into `Aikido.RuntimeStore`, so child restarts continue
  to use the current parent relationship instead of stale startup metadata.

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

  use Ash.TypedStruct

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

    field :restart, Aikido.Types.Validated,
      allow_nil?: false,
      default: :transient,
      constraints: [
        type: :atom,
        constraints: [],
        validation: {Aikido.Directives, :validate_restart_policy, []}
      ],
      description: "Restart policy for the child"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for SpawnAgent."
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema
end
