defmodule Aikido.Slice.Extension.Verifiers.Validate do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    routes = Verifier.get_entities(dsl, [:slice])
    schedules = Verifier.get_entities(dsl, [:schedules])

    with :ok <- validate_route_declarations(dsl, routes),
         :ok <- validate_snapshot_callbacks(dsl),
         :ok <- validate_embedded_resource(dsl) do
      validate_routed_actions(dsl, routes ++ schedules)
    end
  end

  defp validate_route_declarations(dsl, routes) do
    generated = Verifier.get_persisted(dsl, :aikido_generated_handlers, %{})
    reserved_handler = Enum.find([:create, :update], &Map.has_key?(generated, &1))

    cond do
      Enum.any?(routes, &(&1.public? && String.contains?(&1.type, "*"))) ->
        error("Public routes require a concrete type; mark wildcard routes public? false")

      reserved_handler ->
        error(
          "Generated reducer action #{inspect(reserved_handler)} is reserved for native slice initialization actions; use a different signal definition or implementation name"
        )

      Enum.any?(routes, &invalid_signal_reference?/1) ->
        error(
          "Typed routes require Aikido.Signal definitions and native Ash action implementations"
        )

      true ->
        :ok
    end
  end

  defp validate_snapshot_callbacks(dsl) do
    resource = Verifier.get_persisted(dsl, :module)

    if function_exported?(resource, :externalize, 1) ==
         function_exported?(resource, :reinstate, 1),
       do: :ok,
       else: error("Slice externalize/1 and reinstate/1 must be implemented together")
  end

  defp validate_embedded_resource(dsl) do
    if Ash.Resource.Info.embedded?(dsl),
      do: :ok,
      else: error("Aikido.Slice.Extension requires data_layer: :embedded")
  end

  defp validate_routed_actions(dsl, routes) do
    if Enum.any?(routes, &invalid_action?(dsl, &1.action)) do
      error(
        "Slice routes require generic Ash actions with a :state argument and Aikido.Types.ActionResult return type"
      )
    else
      :ok
    end
  end

  defp invalid_signal_reference?(entity) do
    definition = Map.get(entity, :signal_module)
    implementation = Map.get(entity, :implementation)

    (!is_nil(definition) && !Aikido.Signal.Routes.valid_definition?(definition)) ||
      (!is_nil(implementation) && !Aikido.Signal.Routes.valid_implementation?(implementation))
  end

  defp invalid_action?(dsl, name) do
    resource = Spark.Dsl.Verifier.get_persisted(dsl, :module)

    definition =
      case name do
        action when is_atom(action) -> Ash.Resource.Info.action(dsl, action)
        {^resource, action} -> Ash.Resource.Info.action(dsl, action)
        {other, action} -> Ash.Resource.Info.action(other, action)
        _ -> nil
      end

    case definition do
      %{type: :action, returns: Aikido.Types.ActionResult, arguments: arguments} ->
        !Enum.any?(arguments, &(&1.name == :state))

      _ ->
        true
    end
  end

  defp error(message),
    do: {:error, Spark.Error.DslError.exception(message: message, path: [:slice])}
end
