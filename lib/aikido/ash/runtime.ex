defmodule Aikido.Ash.Runtime do
  @moduledoc false
  alias Aikido.AgentServer

  def command_context(input, context) do
    application_context = Map.drop(input.context, [:private, :aikido_runtime_options, :aikido])

    context
    |> Ash.Scope.to_opts(context: application_context)
    |> Map.new()
  end

  def reference(resource, id, pid), do: %{id: id, pid: pid, resource: resource}

  def resolve(resource, %{id: id}), do: resolve(resource, id)

  def resolve(resource, id) when is_binary(id) do
    case Aikido.Durable.lookup(
           Aikido.durable_supervisor_name(Aikido.Dsl.Agent.Info.agent_instance!(resource)),
           id
         ) do
      :error -> {:error, "Agent #{id} is not running"}
      {:ok, pid} -> resolve(resource, pid)
    end
  end

  def resolve(resource, pid) when is_pid(pid) do
    AgentServer.state(pid, fn state ->
      if state.agent.agent_module == resource,
        do: {:ok, {state.agent.id, pid}},
        else: {:error, :different_resource}
    end)
  end

  def resolve(_resource, _), do: {:error, "Expected an agent ID, PID, or reference"}

  def snapshot(resource, pid) do
    AgentServer.state(pid, fn state ->
      if state.agent.agent_module == resource do
        {:ok, record(resource, state.agent)}
      else
        {:error, :different_resource}
      end
    end)
  end

  defp record(resource, agent) do
    attributes =
      Map.new(Ash.Resource.Info.attributes(resource), fn attr ->
        value =
          cond do
            attr.name == :id ->
              agent.id

            attr.name in Aikido.Dsl.Agent.Info.state_fields(resource) ->
              agent.state
              |> Map.get(Aikido.Dsl.Agent.Info.agent_path!(resource), %{})
              |> Map.get(attr.name)

            true ->
              Map.get(agent.state, attr.name)
          end

        value =
          if is_map(value) && !is_struct(value) && Spark.Dsl.is?(attr.type, Ash.Resource),
            do: struct(attr.type, value),
            else: value

        {attr.name, value}
      end)

    struct(resource, attributes)
  end

  def safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, "Agent runtime unavailable: #{inspect(reason)}"}
  end
end
