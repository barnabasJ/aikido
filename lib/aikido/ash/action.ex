defmodule Aikido.Ash.Action do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    case input.action.name do
      :start ->
        Aikido.Ash.Runtime.start(input.resource, input)

      :stop ->
        Aikido.Ash.Runtime.stop(input.resource, input.arguments.agent)

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
        Aikido.Ash.Runtime.list(input.resource, input.arguments)

      _ ->
        Aikido.Ash.Runtime.signal(input.resource, input)
    end
  end
end
