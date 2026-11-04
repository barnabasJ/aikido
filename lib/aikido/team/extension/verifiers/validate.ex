defmodule Aikido.Team.Extension.Verifiers.Validate do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    entities = Verifier.get_entities(dsl, [:team])
    members = Enum.filter(entities, &match?(%Aikido.Team.Member{}, &1))
    names = Enum.map(members, & &1.name)
    instance = Verifier.get_option(dsl, [:agent], :instance)
    raw = Verifier.get_option(dsl, [:team], :topology, %{})

    cond do
      Aikido.Agent.Extension not in Spark.extensions(dsl) ->
        error("requires the Aikido.Agent.Extension extension")

      Enum.any?(names, &Map.has_key?(raw, &1)) ->
        error("Duplicate topology member")

      Enum.any?(entities, &(Aikido.Agent.Info.agent_instance!(&1.resource) != instance)) ->
        error("All team members must use the team's Aikido instance")

      true ->
        config = Verifier.get_persisted(dsl, :aikido_team_config)

        with :ok <- validate_reconciled_inheritance(dsl, config),
             {:ok, _topology} <-
               Aikido.Team.Topology.build(config.topology.nodes, instance, config.max_members) do
          :ok
        else
          {:error, %Spark.Error.DslError{}} = failure -> failure
          {:error, reason} -> error(inspect(reason))
        end
    end
  end

  defp validate_reconciled_inheritance(dsl, config) do
    fields = Verifier.get_persisted(dsl, :aikido_state_fields, [])

    Enum.reduce_while(config.reconcile_inherit, :ok, fn field, :ok ->
      attribute = Ash.Resource.Info.attribute(dsl, field)

      cond do
        field not in config.inherit ->
          {:halt,
           error("reconcile_inherit fields must also be declared in inherit: #{inspect(field)}")}

        field not in fields || is_nil(attribute) ->
          {:halt, error("reconcile_inherit requires an own-state attribute: #{inspect(field)}")}

        Aikido.Team.InheritedAttributes.restricted_attribute?(attribute) ->
          {:halt,
           error(
             "reconcile_inherit cannot change identity or sensitive fields: #{inspect(field)}"
           )}

        !attribute.writable? ->
          {:halt, error("reconcile_inherit requires a writable attribute: #{inspect(field)}")}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp error(message),
    do:
      {:error,
       Spark.Error.DslError.exception(message: "Invalid team: " <> message, path: [:team])}
end
