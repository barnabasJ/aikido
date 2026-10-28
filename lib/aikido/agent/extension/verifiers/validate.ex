defmodule Aikido.Agent.Extension.Verifiers.Validate do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @reserved_handlers [
    :start,
    :stop,
    :delete,
    :list,
    :inspect,
    :initialize,
    :__aikido_apply_state__,
    :__aikido_initialize_state__
  ]

  @impl true
  def verify(dsl) do
    with :ok <- validate_public_names(dsl),
         :ok <- validate_signal_definitions(dsl),
         :ok <- validate_schedule_ids(dsl),
         :ok <- validate_codec_pairs(dsl),
         :ok <- validate_route_actions(dsl) do
      validate_state_paths(dsl)
    end
  end

  defp public_signals(dsl) do
    dsl
    |> Verifier.get_entities([:agent])
    |> Enum.filter(&(match?(%Aikido.Agent.Route{}, &1) && &1.public?))
  end

  defp validate_public_names(dsl) do
    signals = public_signals(dsl)
    resource = Verifier.get_persisted(dsl, :module)
    generated = Verifier.get_persisted(dsl, :aikido_generated_handlers, %{})

    duplicate =
      signals |> Enum.frequencies_by(& &1.name) |> Enum.find(fn {_, count} -> count > 1 end)

    reserved_signal =
      Enum.find(signals, &(!is_nil(&1.implementation) && &1.name in @reserved_handlers))

    reserved_handler = Enum.find(@reserved_handlers, &Map.has_key?(generated, &1))

    cond do
      duplicate ->
        error("Public route names must be unique: #{inspect(elem(duplicate, 0))}", resource)

      reserved_signal ->
        error(
          "Generated public signal #{inspect(reserved_signal.name)} is reserved for agent lifecycle or initialization; use a different public signal name",
          resource
        )

      reserved_handler ->
        error(
          "Generated reducer action #{inspect(reserved_handler)} is reserved for agent lifecycle or initialization; use a different signal definition or implementation name",
          resource
        )

      true ->
        :ok
    end
  end

  defp validate_signal_definitions(dsl) do
    routes = public_signals(dsl) ++ Verifier.get_persisted(dsl, :aikido_agent_routes, [])

    if Enum.any?(routes, &invalid_signal_reference?/1),
      do:
        error(
          "Typed routes require Aikido.Signal definitions and native Ash action implementations"
        ),
      else: :ok
  end

  defp validate_schedule_ids(dsl) do
    ids = dsl |> Verifier.get_persisted(:expanded_agent_schedules, []) |> Enum.map(& &1.job_id)

    if length(ids) != length(Enum.uniq(ids)),
      do:
        error(
          "Agent schedules require unique job IDs; use distinct job_id options for schedules sharing a signal",
          Verifier.get_persisted(dsl, :module)
        ),
      else: :ok
  end

  defp validate_codec_pairs(dsl) do
    resource = Verifier.get_persisted(dsl, :module)

    cond do
      function_exported?(resource, :externalize, 1) != function_exported?(resource, :reinstate, 1) ->
        error("Agent externalize/1 and reinstate/1 must be implemented together", resource)

      function_exported?(resource, :checkpoint, 2) != function_exported?(resource, :restore, 2) ->
        error("Agent checkpoint/2 and restore/2 must be implemented together", resource)

      true ->
        :ok
    end
  end

  defp validate_route_actions(dsl) do
    routes = Verifier.get_persisted(dsl, :aikido_agent_routes, [])

    if Enum.any?(routes, &invalid_action?(dsl, &1.action)),
      do:
        error(
          "Agent routes require generic Ash actions with a :state argument and Aikido.Types.ActionResult return type",
          Verifier.get_persisted(dsl, :module)
        ),
      else: :ok
  end

  defp validate_state_paths(dsl) do
    path = Verifier.get_option(dsl, [:agent], :path)

    mounts =
      dsl
      |> Verifier.get_entities([:agent])
      |> Enum.filter(&match?(%Aikido.Agent.SliceMount{}, &1))

    reserved = [path | Enum.map(mounts, & &1.path)]
    fields = Verifier.get_persisted(dsl, :aikido_state_fields, [])

    cond do
      :id in reserved ->
        error("The :id attribute is reserved for the agent identity")

      Enum.any?(public_signals(dsl), &String.contains?(&1.type, "*")) ->
        error("Public routes require a concrete type; mark wildcard routes public? false")

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

  defp invalid_signal_reference?(entity) do
    definition = Map.get(entity, :signal_module)
    implementation = Map.get(entity, :implementation)

    (!is_nil(definition) && !Aikido.Signal.Routes.valid_definition?(definition)) ||
      (!is_nil(implementation) && !Aikido.Signal.Routes.valid_implementation?(implementation))
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
