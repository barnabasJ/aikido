defmodule Aikido.Cron.Directives.Cancel do
  @moduledoc """
  Cancel a recurring cron job in supervised work without blocking the agent.

  The descriptor queues an ordered cancellation request. The runtime retires
  ownership when that request is processed, before starting shutdown. Shutdown
  completion publishes `aikido.agent.cron.cancelled`; it cannot remove a newer
  job registered under the same ID.
  """
  use Aikido.Directive

  typed_struct do
    field :job_id, :term do
      allow_nil? false
      description "Logical cron job id within the agent"
    end
  end

  @impl true
  def exec(%{job_id: logical_id}, input_signal, state) do
    request =
      Aikido.Cron.Signals.CancelRequested.new!(%{job_id: logical_id},
        source: "/agent/#{state.id}"
      )

    Aikido.AgentServer.cast(self(), Aikido.Signal.inherit(request, input_signal))
    :ok
  end
end
