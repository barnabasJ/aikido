defmodule Aikido.Signal.Delivery do
  @moduledoc "Internal correlated delivery that preserves recipient-owned execution authority."

  @protocols [Aikido.Team.Delivery, Aikido.Ownership.Delivery, Aikido.Thread.Delivery]

  @doc "Send one internal signal with runtime-owned sender and parent provenance."
  def send(protocol, target, signal, runtime, correlation) when protocol in @protocols do
    sender = %{
      id: runtime.id,
      pid: self(),
      resource: runtime.agent_module,
      aikido: runtime.aikido,
      partition: runtime.partition,
      parent: Aikido.Ownership.parent(runtime)
    }

    Kernel.send(target, {__MODULE__, protocol, sender, signal, correlation})
    :ok
  end

  @doc "Validate the owning protocol before binding the recipient's activation scope."
  def receive_signal(
        runtime,
        protocol,
        %{id: _, pid: _, resource: _, aikido: _, partition: _} = sender,
        %Aikido.Signal{data: %{}} = signal,
        correlation
      )
      when protocol in @protocols and is_map(correlation) do
    if protocol.permitted?(runtime, sender, signal, correlation),
      do: {:ok, delivery_scope(runtime, protocol, sender, signal, correlation)},
      else: :ignore
  end

  def receive_signal(_runtime, _protocol, _sender, _signal, _correlation), do: :ignore

  defp delivery_scope(_runtime, Aikido.Thread.Delivery, _sender, signal, %{kind: :request}),
    do: signal

  defp delivery_scope(runtime, Aikido.Team.Delivery, sender, signal, %{kind: kind})
       when kind in [
              :inheritance,
              :inheritance_result,
              :stop,
              :stop_cleanup,
              :stop_result,
              :stop_cleanup_result,
              :owned_child_exit,
              :stop_monitor
            ],
       do: bind_recipient_scope(runtime, sender, signal)

  defp delivery_scope(runtime, _protocol, sender, signal, _correlation),
    do: bind_scope(runtime, sender, signal)

  defp bind_scope(%{bound_execution_scope: nil}, _sender, signal), do: signal

  defp bind_scope(runtime, sender, signal), do: bind_recipient_scope(runtime, sender, signal)

  defp bind_recipient_scope(runtime, sender, signal) do
    provenance = Map.take(sender, [:id, :resource, :aikido, :partition])
    scope = runtime.bound_execution_scope || %{}
    context = Map.put(scope[:context] || %{}, :aikido_sender, provenance)
    Aikido.Signal.put_ctx(signal, Map.put(scope, :context, context))
  end
end
