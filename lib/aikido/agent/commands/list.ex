defmodule Aikido.Agent.Commands.List do
  @moduledoc "External Ash command boundary. Reads live agent snapshots with native filtering, sorting and pagination under the caller scope."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.Runtime

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    arguments = input.arguments
    options = Ash.Scope.to_opts(context, context: input.context)

    Runtime.catch_runtime_exit(fn ->
      with {:ok, records} <- collect_live_snapshots(resource),
           {:ok, records} <- filter_snapshots(records, resource, arguments[:filter], options) do
        {:ok, sort_and_paginate(records, arguments)}
      end
    end)
  end

  defp collect_live_snapshots(resource) do
    resource
    |> Aikido.Agent.Info.agent_instance!()
    |> Aikido.durable_supervisor_name()
    |> Aikido.Durable.members()
    |> Enum.reduce_while({:ok, []}, fn {_id, pid}, {:ok, records} ->
      case live_snapshot(resource, pid) do
        {:ok, record} ->
          {:cont, {:ok, [record | records]}}

        {:error, reason} when reason in [:different_resource, :not_running] ->
          {:cont, {:ok, records}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp filter_snapshots(records, resource, expression, options) do
    with {:ok, filter} <- Ash.Filter.parse(resource, expression, %{eval?: true}) do
      Ash.Filter.Runtime.filter_matches(
        Ash.Resource.Info.domain(resource),
        records,
        filter,
        options
      )
    end
  end

  defp sort_and_paginate(records, arguments) do
    records
    |> Ash.Actions.Sort.runtime_sort(Map.get(arguments, :sort, []))
    |> Enum.drop(Map.get(arguments, :offset, 0))
    |> take_limit(arguments[:limit])
  end

  defp take_limit(records, nil), do: records
  defp take_limit(records, limit), do: Enum.take(records, limit)

  # Registry cleanup can lag process termination, including immediately after
  # destroy. A read enumerates live agents, so omit entries that have exited.
  defp live_snapshot(resource, pid) do
    Runtime.snapshot(resource, pid)
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :not_running}
  end
end
