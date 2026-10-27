defmodule Aikido.Directives.AdoptChild do
  @moduledoc """
  Attach an orphaned or unattached child agent to the current parent.

  This directive is the explicit reattachment path for Aikido's logical
  hierarchy. It updates the live child runtime so the child can resume
  parent-directed communication via `ctx.parent`.

  Adoption is explicit. Aikido does not automatically reconnect children
  when a logical parent restarts.

  Adoption updates the child runtime. Its DurableServer callback persists the
  updated parent binding before returning, so recovery restores that relationship.

  ## Fields

  - `child` - Child PID or child agent id to adopt
  - `tag` - Tag for tracking this adopted child
  - `meta` - Metadata to write into the child's new parent reference
  """

  use Aikido.Directive

  typed_struct do
    field :child, :term do
      allow_nil? false
      description "Child PID or child id"
    end

    field :tag, :term do
      allow_nil? false
      description "Tag for tracking this adopted child"
    end

    field :meta, :map do
      allow_nil? false
      default %{}
      description "Metadata to pass to the adopted child"
    end
  end

  @doc "Send one attachment command; the child's startup signal acknowledges the new binding."
  @impl true
  def exec(%{child: child, tag: tag, meta: meta}, _signal, state) do
    pid =
      if is_pid(child),
        do: child,
        else:
          (case Aikido.Durable.lookup(Aikido.durable_supervisor_name(state.aikido), child,
                  partition: state.partition
                ) do
             {:ok, pid} -> pid
             :error -> nil
           end)

    if is_pid(pid) and pid != self() and not Map.has_key?(Aikido.Ownership.children(state), tag) do
      parent =
        Aikido.Ownership.ParentRef.new!(%{
          pid: self(),
          id: state.id,
          partition: state.partition,
          tag: tag,
          meta: meta
        })

      GenServer.cast(pid, {:adopt_parent, parent})
    end

    :ok
  end
end
