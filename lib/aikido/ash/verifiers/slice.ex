defmodule Aikido.Ash.Verifiers.Slice do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    routes = Verifier.get_entities(dsl, [:slice])
    schedules = Verifier.get_entities(dsl, [:schedules])

    cond do
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
    case Ash.Resource.Info.action(dsl, name) do
      %{type: :action, returns: Aikido.ActionResult, arguments: arguments} ->
        !Enum.any?(arguments, &(&1.name == :state))

      _ ->
        true
    end
  end

  defp error(message),
    do: {:error, Spark.Error.DslError.exception(message: message, path: [:slice])}
end
