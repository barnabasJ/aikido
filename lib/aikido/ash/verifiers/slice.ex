defmodule Aikido.Ash.Verifiers.Slice do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    routes = Verifier.get_entities(dsl, [:slice])
    schedules = Verifier.get_entities(dsl, [:schedules])

    resource = Verifier.get_persisted(dsl, :module)

    cond do
      function_exported?(resource, :externalize, 1) != function_exported?(resource, :reinstate, 1) ->
        error("Slice externalize/1 and reinstate/1 must be implemented together")

      !Ash.Resource.Info.embedded?(dsl) ->
        error("Aikido.Ash.Slice requires data_layer: :embedded")

      Enum.any?(routes ++ schedules, &invalid_action?(dsl, &1.action)) ->
        error(
          "Slice routes require generic Ash actions with a :state argument and Aikido.ActionResult return type"
        )

      true ->
        :ok
    end
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
      %{type: :action, returns: Aikido.ActionResult, arguments: arguments} ->
        !Enum.any?(arguments, &(&1.name == :state))

      _ ->
        true
    end
  end

  defp error(message),
    do: {:error, Spark.Error.DslError.exception(message: message, path: [:slice])}
end
