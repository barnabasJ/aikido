defmodule Aikido.Directives.AdoptChild do
  @moduledoc """
  Attach an orphaned or unattached child agent to the current parent.

  This directive is the explicit reattachment path for Aikido's logical
  hierarchy. It updates the live child runtime so the child can resume
  parent-directed communication via `ctx.parent`.

  Adoption is explicit. Aikido does not automatically reconnect children
  when a logical parent restarts.

  Adoption updates the live runtime and the instance `Aikido.RuntimeStore`
  binding, so later child restarts rehydrate the adopted parent relationship.

  ## Fields

  - `child` - Child PID or child agent id to adopt
  - `tag` - Tag for tracking this adopted child
  - `meta` - Metadata to write into the child's new parent reference
  """

  use Aikido.Directive

  typed_struct do
    field :child, :term, allow_nil?: false, description: "Child PID or child id"
    field :tag, :term, allow_nil?: false, description: "Tag for tracking this adopted child"

    field :meta, :map,
      allow_nil?: false,
      default: %{},
      description: "Metadata to pass to the adopted child"
  end

  @doc """
  Pure I/O directive: pushes a fresh `%ParentRef{}` into the live child
  via `AgentServer.adopt_parent/2`. The child's
  `notify_parent_of_startup/1` then casts `aikido.agent.child.started`
  back to this agent, where `maybe_track_child_started/2` records the
  `%ChildInfo{}` and creates the parent-side monitor.

  This is the directive form. The imperative
  `Aikido.AgentServer.adopt_child/4` (a `handle_call` callback) keeps
  doing the state mutation directly; only the directive defers to the
  cascade.

  Async window: between the directive returning and the natural
  `child.started` arriving, `state.children[tag]` is `nil`. Tests should
  use `AgentServer.await_child/3` rather than peeking at `state.children`
  immediately.
  """

  alias Aikido.AgentServer
  alias Aikido.AgentServer.{ParentRef, State}

  require Logger

  @impl true
  def exec(%{child: child, tag: tag, meta: meta}, _input_signal, state) do
    with :ok <- ensure_tag_available(state, tag),
         {:ok, child_pid} <- resolve_child(child, state),
         :ok <- ensure_not_self(child_pid),
         {:ok, child_runtime} <- adopt_child(child_pid, tag, meta, state) do
      Logger.debug(
        "AgentServer #{state.id} initiated adoption of child #{child_runtime.id} with tag #{inspect(tag)}"
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "AgentServer #{state.id} failed to adopt child #{inspect(child)} with tag #{inspect(tag)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ensure_tag_available(state, tag) do
    case State.get_child(state, tag) do
      nil -> :ok
      _child -> {:error, {:tag_in_use, tag}}
    end
  end

  defp resolve_child(pid, _state) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :child_not_alive}
  end

  defp resolve_child(id, state) when is_binary(id) do
    case Aikido.whereis(state.aikido, id, partition: state.partition) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :child_not_found}
    end
  end

  defp resolve_child(child, _state), do: {:error, {:invalid_child, child}}

  defp ensure_not_self(pid) when pid == self(), do: {:error, :cannot_adopt_self}
  defp ensure_not_self(_pid), do: :ok

  defp adopt_child(child_pid, tag, meta, state) do
    parent_ref =
      ParentRef.new!(%{
        pid: self(),
        id: state.id,
        partition: state.partition,
        tag: tag,
        meta: meta
      })

    AgentServer.adopt_parent(child_pid, parent_ref)
  end
end
