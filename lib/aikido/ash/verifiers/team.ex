defmodule Aikido.Ash.Verifiers.Team do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    entities = Verifier.get_entities(dsl, [:team])
    members = Enum.filter(entities, &match?(%Aikido.Ash.Team.Member{}, &1))
    names = Enum.map(members, & &1.name)
    instance = Verifier.get_option(dsl, [:agent], :instance)
    raw = Verifier.get_option(dsl, [:team], :topology, %{})

    cond do
      Aikido.Ash.Agent not in Spark.extensions(dsl) ->
        error("requires the Aikido.Ash.Agent extension")

      Enum.any?(names, &Map.has_key?(raw, &1)) ->
        error("Duplicate topology member")

      Enum.any?(entities, &(Aikido.Ash.Runtime.option(&1.resource, :instance) != instance)) ->
        error("All team members must use the team's Aikido instance")

      true ->
        config = Verifier.get_persisted(dsl, :aikido_team_config)

        case Aikido.Ash.Team.Topology.build(config.topology.nodes, instance, config.max_members) do
          {:ok, _topology} -> :ok
          {:error, reason} -> error(inspect(reason))
        end
    end
  end

  defp error(message),
    do:
      {:error,
       Spark.Error.DslError.exception(message: "Invalid team: " <> message, path: [:team])}
end
