defmodule Aikido.Agent.Reference do
  @moduledoc "A durable agent address without a process identifier or execution credentials."
  use Ash.TypedStruct

  typed_struct do
    field :id, :string do
      description "Saved agent identity within its partition."
      allow_nil? false
      constraints trim?: false, allow_empty?: true
    end

    field :resource, :atom do
      description "Agent resource owning this identity."
      allow_nil? false
    end

    field :aikido, :atom do
      description "Aikido runtime hosting the durable identity."
      allow_nil? false
    end

    field :partition, :term do
      description "Partition used by the native DurableServer address."
    end
  end

  @doc "Construct an address from the current runtime, without I/O."
  def from_runtime(runtime),
    do:
      new!(
        id: runtime.id,
        resource: runtime.agent_module,
        aikido: runtime.aikido,
        partition: runtime.partition
      )

  @doc "Whether runtime-derived delivery provenance names this exact durable address."
  def matches?(%__MODULE__{} = reference, %{id: _, resource: _, aikido: _, partition: _} = sender) do
    reference.id == sender.id && reference.resource == sender.resource &&
      reference.aikido == sender.aikido && reference.partition == sender.partition
  end

  def matches?(_reference, _sender), do: false

  @doc "Resolve a running incarnation without activating an offline consumer."
  def lookup(reference) do
    Aikido.Durable.lookup(
      Aikido.durable_supervisor_name(reference.aikido),
      reference.id,
      partition: reference.partition
    )
  end
end
