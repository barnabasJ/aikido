defmodule Aikido.Ash.Commands.List do
  @moduledoc "External Ash command boundary. Reads live agent snapshots with native filtering, sorting and pagination under the caller scope."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Runtime

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    arguments = input.arguments
    options = Ash.Scope.to_opts(context, context: input.context)

    Runtime.safe(fn ->
      Enum.reduce_while(
        Aikido.Durable.members(
          Aikido.durable_supervisor_name(Aikido.Ash.Agent.Info.agent_instance!(resource))
        ),
        {:ok, []},
        fn
          {_id, pid}, {:ok, records} ->
            case live_snapshot(resource, pid) do
              {:ok, record} -> {:cont, {:ok, [record | records]}}
              {:error, :different_resource} -> {:cont, {:ok, records}}
              {:error, :not_running} -> {:cont, {:ok, records}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      )
      |> case do
        {:ok, records} ->
          with {:ok, filter} <-
                 Ash.Filter.parse(resource, Map.get(arguments, :filter), %{eval?: true}),
               {:ok, records} <-
                 Ash.Filter.Runtime.filter_matches(
                   Ash.Resource.Info.domain(resource),
                   records,
                   filter,
                   options
                 ) do
            records =
              records
              |> Ash.Actions.Sort.runtime_sort(Map.get(arguments, :sort, []))
              |> Enum.drop(Map.get(arguments, :offset, 0))

            {:ok, if(arguments[:limit], do: Enum.take(records, arguments.limit), else: records)}
          end

        error ->
          error
      end
    end)
  end

  # Registry cleanup can lag process termination, including immediately after
  # destroy. A read enumerates live agents, so omit entries that have exited.
  defp live_snapshot(resource, pid) do
    Runtime.snapshot(resource, pid)
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :not_running}
  end
end
