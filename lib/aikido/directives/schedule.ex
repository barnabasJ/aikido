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
    field :delay_ms, :integer do
      allow_nil? false
      description "Delay in milliseconds"
      constraints min: 0
    end

    field :message, :term do
      allow_nil? false
      description "Message to send after delay"
    end
  end

  alias Aikido.AgentServer.Signal.Scheduled

  @impl true
  def exec(%{delay_ms: delay, message: message}, input_signal, state) do
    signal =
      case message do
        %Aikido.Signal{} = s ->
          s

        other ->
          Scheduled.new!(
            %{message: other},
            source: "/agent/#{state.id}"
          )
      end

    signal =
      signal
      |> Aikido.Directive.materialize_signal()
      |> Aikido.Signal.inherit(input_signal)

    Process.send_after(self(), {:scheduled_signal, signal}, delay)
    :ok
  end
end
