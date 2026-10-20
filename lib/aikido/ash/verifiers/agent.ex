defmodule Aikido.Ash.Verifiers.Agent do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    path = Verifier.get_option(dsl, [:agent], :path)
    entities = Verifier.get_entities(dsl, [:agent])
    mounts = Enum.filter(entities, &match?(%Aikido.Dsl.Agent.SliceMount{}, &1))
    signals = Enum.filter(entities, &match?(%Aikido.Ash.Agent.Signal{}, &1))
    routes = Verifier.get_persisted(dsl, :aikido_agent_routes, [])
    reserved = [path | Enum.map(mounts, & &1.path)]
    fields = Verifier.get_persisted(dsl, :aikido_state_fields, [])

    resource = Verifier.get_persisted(dsl, :module)
    schedules = Verifier.get_persisted(dsl, :expanded_agent_schedules, [])
    job_ids = Enum.map(schedules, & &1.job_id)

    cond do
      length(job_ids) != length(Enum.uniq(job_ids)) ->
        error(
          "Agent schedules require unique job IDs; use distinct job_id options for schedules sharing a signal",
          resource
        )

      function_exported?(resource, :externalize, 1) != function_exported?(resource, :reinstate, 1) ->
        error("Agent externalize/1 and reinstate/1 must be implemented together", resource)

      function_exported?(resource, :checkpoint, 2) != function_exported?(resource, :restore, 2) ->
        error("Agent checkpoint/2 and restore/2 must be implemented together", resource)

      Enum.any?(routes, &invalid_action?(dsl, &1.action)) ->
        error(
          "Agent routes require generic Ash actions with a :state argument and Aikido.Types.ActionResult return type",
          resource
        )

      :id in reserved ->
        error("The :id attribute is reserved for the agent identity")

      Enum.any?(signals, &String.contains?(&1.type, "*")) ->
        error("Public signals require a concrete type; mark wildcard slice actions public? false")

      Enum.any?(fields, &(&1 in reserved)) ->
        error(
          "Resource attributes cannot collide with the agent state path or mounted slice paths"
        )

      Verifier.get_persisted(dsl, :aikido_team_slice) && :topology in fields ->
        error("Team resources reserve :topology for the startup graph")

      true ->
        :ok
    end
  end

  defp invalid_action?(dsl, {resource, name}) do
    definition =
      if resource == Verifier.get_persisted(dsl, :module),
        do: Ash.Resource.Info.action(dsl, name),
        else: Ash.Resource.Info.action(resource, name)

    case definition do
      %{type: :action, returns: Aikido.Types.ActionResult, arguments: arguments} ->
        !Enum.any?(arguments, &(&1.name == :state))

      _ ->
        true
    end
  end

  defp error(message, resource \\ nil),
    do:
      {:error, Spark.Error.DslError.exception(message: message, module: resource, path: [:agent])}
end
