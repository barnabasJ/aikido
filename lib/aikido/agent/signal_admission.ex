defmodule Aikido.Agent.SignalAdmission do
  @moduledoc "Native owning-resource admission before public routed reducers can plan effects."

  @doc "Authorize the owner's public signal action even when its reducer returns no changes."
  def authorize(signal, context, targets) do
    if context[:authorize?] == false || Ash.Resource.Info.authorizers(context.agent_module) == [] do
      :ok
    else
      context.agent_module
      |> Spark.Dsl.Extension.get_persisted(:aikido_public_admission_routes, [])
      |> Enum.filter(fn route ->
        is_struct(route, Aikido.Agent.Route) && route.public? &&
          Enum.any?(targets, fn {reference, _params} -> reference == route.action end)
      end)
      |> matching_routes(signal)
      |> Enum.uniq_by(& &1.name)
      |> Enum.reduce_while(:ok, fn route, :ok ->
        case authorize_command(route, signal, context) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp matching_routes(routes, signal) do
    router =
      routes
      |> Enum.map(fn route ->
        if is_function(route.match, 1),
          do: {route.type, route.match, route, route.priority},
          else: {route.type, route, route.priority}
      end)
      |> Aikido.Signal.Router.new!()

    case Aikido.Signal.Router.route(router, signal) do
      {:ok, matched} -> matched
      {:error, %{details: %{reason: :no_handlers_found}}} -> []
    end
  end

  defp authorize_command(route, signal, context) do
    resource = context.agent_module
    action = Ash.Resource.Info.action(resource, route.name)
    flat = Spark.Dsl.Extension.get_persisted(resource, :aikido_flat_signal_inputs, [])

    arguments =
      if route.name not in flat && Enum.any?(action.arguments, &(&1.name == :data)),
        do: %{agent: context.agent_pid, data: signal.data},
        else: Map.put(signal.data || %{}, :agent, context.agent_pid)

    source_context = Map.put(context[:context] || %{}, :aikido, Map.put(context, :signal, signal))
    options = Ash.Scope.to_opts(context, context: source_context)

    input =
      Ash.ActionInput.for_action(
        resource,
        route.name,
        arguments,
        Keyword.put(options, :skip_unknown_inputs, [:*])
      )

    case Ash.can(input, context[:actor],
           scope: context,
           context: source_context,
           maybe_is: false,
           pre_flight?: false,
           validate?: true,
           return_forbidden_error?: true
         ) do
      {:ok, true} -> :ok
      {:ok, false, error} -> {:error, Ash.Error.to_error_class(error)}
      {:error, error} -> {:error, Ash.Error.to_error_class(error)}
      {:ok, false} -> {:error, Ash.Error.Forbidden.exception([])}
    end
  end
end
