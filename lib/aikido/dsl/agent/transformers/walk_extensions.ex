defmodule Aikido.Dsl.Agent.Transformers.WalkExtensions do
  @moduledoc "Compiles slice mounts, middleware and action ownership for native agent resources."
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def after?(Aikido.Ash.Transformers.Agent), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    instances =
      dsl
      |> Transformer.get_entities([:agent])
      |> Enum.filter(&match?(%Aikido.Dsl.Agent.SliceMount{}, &1))
      |> Enum.map(fn mount ->
        Code.ensure_compiled!(mount.module)
        Aikido.Slice.Instance.new({mount.module, mount.options}, mount.path)
      end)

    middleware =
      dsl
      |> Transformer.get_option([:agent], :middleware, [])
      |> Enum.map(fn
        module when is_atom(module) -> {module, %{}}
        {module, options} -> {module, Map.new(options)}
      end)

    pairs =
      Enum.flat_map(instances, fn instance ->
        Enum.map(Aikido.Dsl.Slice.Info.actions(instance.module), &{&1, instance.path})
      end)

    own_path = Transformer.get_option(dsl, [:agent], :path)

    own =
      for route <- Transformer.get_persisted(dsl, :aikido_agent_routes, []),
          do: {route.action, own_path}

    paths =
      Enum.group_by(pairs ++ own, &elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {action, paths} -> {action, Enum.uniq(paths)} end)

    {:ok,
     dsl
     |> Transformer.persist(:slice_instances, instances)
     |> Transformer.persist(:middleware_list, middleware)
     |> Transformer.persist(:slice_paths, Enum.map(instances, & &1.path))
     |> Transformer.persist(:slice_paths_for_action, paths)}
  end
end
