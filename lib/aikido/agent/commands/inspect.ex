defmodule Aikido.Agent.Commands.Inspect do
  @moduledoc "External Ash command boundary. Reads a live native resource snapshot and optionally selects its requested fields."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.CommandRuntime

  @impl true
  def run(input, _opts, context) do
    options = Ash.Scope.to_opts(context, context: input.context)

    CommandRuntime.catch_runtime_exit(fn ->
      with {:ok, {_id, pid}} <- CommandRuntime.resolve(input.resource, input.arguments.agent),
           {:ok, record} <- CommandRuntime.snapshot(input.resource, pid, options) do
        {:ok,
         if(input.arguments[:fields],
           do: Map.take(record, input.arguments[:fields]),
           else: record
         )}
      end
    end)
  end
end
