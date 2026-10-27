defmodule Aikido.Agent.Commands.Signal do
  @moduledoc "External Ash command boundary. Delivers a public command with native caller scope and returns a compact signal-processing receipt."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.CommandRuntime

  @impl true
  def run(input, _opts, context) do
    resource = input.resource

    definition =
      resource
      |> Spark.Dsl.Extension.get_entities([:agent])
      |> Enum.find(
        &(match?(%Aikido.Agent.Route{}, &1) && &1.public? && &1.name == input.action.name)
      )

    arguments = Map.delete(input.arguments, :agent)

    payload =
      if input.action.name in Spark.Dsl.Extension.get_persisted(
           resource,
           :aikido_flat_signal_inputs,
           []
         ) do
        arguments
      else
        if Enum.any?(input.action.arguments, &(&1.name == :data)),
          do: Map.get(arguments, :data),
          else: arguments
      end

    CommandRuntime.catch_runtime_exit(fn ->
      with {:ok, {id, pid}} <- CommandRuntime.resolve(resource, input.arguments.agent),
           {:ok, signal} <- Aikido.Signal.new(definition.type, payload, source: "/ash"),
           signal = Aikido.Signal.put_ctx(signal, CommandRuntime.command_context(input, context)),
           {:ok, _} <- dispatch(resource, pid, signal) do
        {:ok,
         Map.merge(CommandRuntime.reference(resource, id, pid), %{
           signal_id: signal.id,
           status: :processed
         })}
      end
    end)
  end

  defp dispatch(resource, pid, signal) do
    if !is_nil(Aikido.Agent.Info.team_config(resource)) &&
         signal.type in ~w(aikido.ash.team.start aikido.ash.team.reconcile aikido.ash.team.add_member aikido.ash.team.remove_member aikido.ash.team.ensure_member aikido.ash.team.stop_member) do
      Aikido.Team.Extension.dispatch_and_await_operation(resource, pid, signal)
    else
      Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :processed} end)
    end
  end
end
