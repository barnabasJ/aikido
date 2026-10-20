defmodule Aikido.Ash.Action do
  @moduledoc """
  I/O adapter for public agent lifecycle, signal and inspection actions.

  Dispatches by the native action name: lifecycle commands activate or stop durable
  agents, signal commands return processing receipts, and inspection/list commands
  read live snapshots. Caller scope accompanies signal delivery; this adapter is
  an external command boundary, not a state reducer.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    case input.action.name do
      :start ->
        Aikido.Ash.Runtime.start(input.resource, input, context)

      :stop ->
        Aikido.Ash.Runtime.stop(input.resource, input.arguments.agent)

      :delete ->
        Aikido.Ash.Runtime.delete(input.resource, input.arguments.agent)

      :inspect ->
        with {:ok, record} <-
               Aikido.Ash.Runtime.inspect_agent(input.resource, input.arguments.agent) do
          {:ok,
           if(input.arguments[:fields],
             do: Map.take(record, input.arguments[:fields]),
             else: record
           )}
        end

      :list ->
        Aikido.Ash.Runtime.list(
          input.resource,
          input.arguments,
          Ash.Scope.to_opts(context, context: input.context)
        )

      _ ->
        Aikido.Ash.Runtime.signal(input.resource, input, context)
    end
  end
end
