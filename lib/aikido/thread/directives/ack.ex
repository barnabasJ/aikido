defmodule Aikido.Thread.Directives.Ack do
  @moduledoc "Acknowledge one offered range only after the consumer's durable SQL commit."
  use Aikido.Directive

  typed_struct do
    field :source, Aikido.Agent.Reference do
      description "Source of the batch whose SQL write completed."
      allow_nil? false
    end

    field :path, :atom do
      description "Source Thread or Team mount."
      default :thread
      allow_nil? false
    end

    field :channel, Aikido.Thread.Types.Channel do
      description "Thread or Team roster acknowledgement contract."
      default :thread
      allow_nil? false
    end

    field :batch, Aikido.Thread.Types.Batch do
      description "Exact committed batch; partial or future cursor claims are not accepted."
      allow_nil? false
    end
  end

  @impl true
  def exec(directive, input, runtime) do
    type =
      if directive.channel == :thread, do: "aikido.thread.ack", else: "aikido.ash.team.ack_roster"

    cursor =
      Aikido.Thread.Types.Cursor.new!(
        generation: directive.batch.generation,
        sequence: directive.batch.last_sequence
      )

    signal =
      Aikido.Signal.new!(type, %{
        consumer: Aikido.Agent.Reference.from_runtime(runtime),
        path: directive.path,
        batch_id: directive.batch.id,
        cursor: cursor
      })

    Aikido.Thread.Delivery.send(directive.source, signal, :request, input, runtime)
  end
end
