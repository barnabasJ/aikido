defmodule Aikido.Agent.Commands.Inspect do
  @moduledoc "External Ash command boundary. Reads a live native resource snapshot and optionally selects its requested fields."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.Runtime

  @impl true
  def run(input, _opts, _context) do
    Runtime.catch_runtime_exit(fn ->
      with {:ok, {_id, pid}} <- Runtime.resolve(input.resource, input.arguments.agent),
           {:ok, record} <- Runtime.snapshot(input.resource, pid) do
        {:ok,
         if(input.arguments[:fields],
           do: Map.take(record, input.arguments[:fields]),
           else: record
         )}
      end
    end)
  end
end
