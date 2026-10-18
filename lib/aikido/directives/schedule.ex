defmodule Aikido.Directives.Schedule do
  @moduledoc """
  Schedule a delayed message to the agent.

  The runtime will send the message back to the agent after the delay.

  ## Fields

  - `delay_ms` - Delay in milliseconds (must be >= 0)
  - `message` - Message to send after delay
  """

  use Aikido.Directive

  typed_struct do
    field :delay_ms, :integer,
      allow_nil?: false,
      description: "Delay in milliseconds",
      constraints: [min: 0]

    field :message, :term, allow_nil?: false, description: "Message to send after delay"
  end

  @type t :: %__MODULE__{}

  alias Aikido.AgentServer.Signal.Scheduled
  alias Aikido.Tracing.Context, as: TraceContext

  @impl true
  def exec(%{delay_ms: delay, message: message}, input_signal, state) do
    signal =
      case message do
        %Jido.Signal{} = s ->
          s

        other ->
          Scheduled.new!(
            %{message: other},
            source: "/agent/#{state.id}"
          )
      end

    traced_signal =
      case TraceContext.propagate_to(signal, input_signal.id) do
        {:ok, s} -> s
        {:error, _} -> signal
      end

    Process.send_after(self(), {:scheduled_signal, traced_signal}, delay)
    :ok
  end
end
