defmodule Aikido.Thread.Delivery do
  @moduledoc "Correlates journal consumers and sources without granting cross-actor read access."
  alias Aikido.Agent.Reference

  @requests [
    "aikido.thread.follow",
    "aikido.thread.ack",
    "aikido.thread.unfollow",
    "aikido.ash.team.follow_roster",
    "aikido.ash.team.ack_roster",
    "aikido.ash.team.unfollow_roster"
  ]

  @replies [
    "aikido.thread.batch",
    "aikido.thread.gap",
    "aikido.thread.available",
    "aikido.thread.rejected"
  ]

  @doc "Admit private replies only when the receiving runtime verified their transport."
  def admit(%{type: type}, context) when type in @replies do
    case context[:__delivery__] do
      %{protocol: __MODULE__, kind: :batch} ->
        :ok

      _ ->
        {:error, Ash.Error.to_error_class(Aikido.Thread.Errors.UntrustedDelivery.exception([]))}
    end
  end

  def admit(_signal, _context), do: :ok

  @doc "Release only a batch whose exact immutable range exists in the confirmed snapshot."
  def release(directive, input, runtime, confirmed_agent) do
    data = directive.signal.data
    mount = Map.get(confirmed_agent.state, data.path)
    journal = if data.channel == :roster && mount, do: mount.membership_journal, else: mount

    if match?(%Aikido.Thread.Slice{}, journal) && journal.generation == data.batch.generation &&
         journal.metadata == Map.get(data, :metadata, %{}) &&
         Enum.filter(
           journal.entries,
           &(&1.seq >= data.batch.first_sequence && &1.seq <= data.batch.last_sequence)
         ) == data.entries do
      send(directive.target, directive.signal, directive.kind, input, runtime)
    else
      :ok
    end
  end

  @doc "Deliver once to a current incarnation; offline consumers remain represented only by their durable cursor."
  def send(target, signal, kind, input, runtime) do
    signal = signal |> Aikido.Directive.materialize_signal() |> Aikido.Signal.inherit(input)

    case Reference.lookup(target) do
      {:ok, pid} ->
        Aikido.Signal.Delivery.send(__MODULE__, pid, signal, runtime, %{
          kind: kind,
          target: target
        })

      :error when kind == :request ->
        unavailable =
          Aikido.Thread.Signals.Unavailable.new!(
            %{
              source: target,
              path: signal.data.path,
              request_type: signal.type,
              channel: channel(signal.type)
            },
            scope: runtime.bound_execution_scope || Aikido.Signal.ctx(signal)
          )

        Kernel.send(self(), {:signal, unavailable})
        :ok

      :error ->
        :ok
    end
  end

  def permitted?(runtime, sender, %{type: type, data: %{consumer: consumer}}, %{
        kind: :request,
        target: target
      })
      when type in @requests,
      do: Reference.matches?(consumer, sender) && target == Reference.from_runtime(runtime)

  def permitted?(runtime, sender, %{type: type, data: %{consumer: consumer, source: source}}, %{
        kind: :batch
      })
      when type in [
             "aikido.thread.batch",
             "aikido.thread.gap",
             "aikido.thread.available",
             "aikido.thread.rejected"
           ] do
    Reference.matches?(source, sender) &&
      Reference.matches?(consumer, %{
        id: runtime.id,
        resource: runtime.agent_module,
        aikido: runtime.aikido,
        partition: runtime.partition
      })
  end

  def permitted?(_runtime, _sender, _signal, _correlation), do: false

  @doc "Report a rejected internal request to its real requester without disclosing source state."
  def reject(runtime, sender, request, error) do
    {failure, message} = rejection(error)
    consumer = Reference.new!(Map.take(sender, [:id, :resource, :aikido, :partition]))

    signal =
      Aikido.Thread.Signals.Rejected.new!(%{
        source: Reference.from_runtime(runtime),
        consumer: consumer,
        path: request.data.path,
        request_id: request.id,
        request_type: request.type,
        channel: channel(request.type),
        failure: failure,
        message: message
      })

    Aikido.Signal.Delivery.send(__MODULE__, sender.pid, signal, runtime, %{kind: :batch})
  end

  defp rejection(%Ash.Error.Forbidden{}),
    do:
      {:forbidden,
       "The source did not authorize this journal request. Restore the consumer's read permission before requesting replay; no batch was accepted."}

  defp rejection(%Ash.Error.Invalid{}),
    do:
      {:invalid,
       "The journal request did not satisfy its native input contract. Check source identity, mount, cursor generation, sequence and batch size before retrying."}

  defp rejection(_error),
    do:
      {:unknown,
       "The source could not process this journal request. Inspect its runtime errors before retrying; no replay or SQL commit is implied."}

  defp channel(type)
       when type in [
              "aikido.ash.team.follow_roster",
              "aikido.ash.team.ack_roster",
              "aikido.ash.team.unfollow_roster"
            ],
       do: :roster

  defp channel(_type), do: :thread
end
