defmodule Aikido.Ash do
  @moduledoc "Helpers for invoking the generic actions shared by agent and team resources."

  def start(resource, attributes \\ %{}, opts \\ []), do: run(resource, :start, attributes, opts)

  def start!(resource, attributes \\ %{}, opts \\ []),
    do: run!(resource, :start, attributes, opts)

  def inspect(resource, agent, opts \\ []), do: run(resource, :inspect, %{agent: agent}, opts)
  def inspect!(resource, agent, opts \\ []), do: run!(resource, :inspect, %{agent: agent}, opts)
  def list(resource, opts \\ []), do: run(resource, :list, %{}, opts)
  def list!(resource, opts \\ []), do: run!(resource, :list, %{}, opts)

  def command(agent, arguments \\ %{}, opts \\ []) do
    resource = Map.get(agent, :resource) || Map.fetch!(agent, :__struct__)
    {action, opts} = Keyword.pop!(opts, :action)
    run(resource, action, Map.put(arguments, :agent, agent.id), opts)
  end

  def command!(agent, arguments \\ %{}, opts \\ []) do
    case command(agent, arguments, opts) do
      {:ok, result} -> result
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  def stop(agent, opts \\ []), do: command(agent, %{}, Keyword.put(opts, :action, :stop))
  def stop!(agent, opts \\ []), do: command!(agent, %{}, Keyword.put(opts, :action, :stop))

  def run(resource, action, arguments, opts \\ []) do
    resource |> Ash.ActionInput.for_action(action, arguments, opts) |> Ash.run_action(opts)
  end

  def run!(resource, action, arguments, opts \\ []) do
    resource |> Ash.ActionInput.for_action(action, arguments, opts) |> Ash.run_action!(opts)
  end
end
