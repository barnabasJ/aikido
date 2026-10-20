defmodule Aikido.Dsl.Agent.Transformers.WalkExtensions do
  @moduledoc """
  Reads the agent's `slices do … end` section + `middleware:` opt and
  produces the runtime instance lists agent introspection consumes:

    * `:slice_instances` — bare-slice mounts (`use Aikido.Slice` modules).
    * `:middleware_list` — ordered middleware (from `middleware: […]`).
    * `:slice_paths_for_action` — compile-time lookup
      `%{{resource, action} => [mount_path, …]}` so AgentServer can fan an
      action's return value out across every mount that owns it.
      Multi-instance mounts of the same slice contribute multiple
      entries; agent-level `signal_routes` entries contribute the
      agent's own path (so an action declared in BOTH a slice and the
      agent's own routes fans out across all of them).

  The agent's `slices do …` block supplies each slice's mount path.

  When a slice contributes a typed DSL section to the host (the
  Spark DSL section contribution mechanism, e.g. `react do … end`),
  this transformer merges the contributed-block opts into the slice's
  config map.
  """

  use Spark.Dsl.Transformer

  alias Aikido.Dsl.Agent.SliceMount
  alias Aikido.Dsl.Slice.Info, as: SliceInfo
  alias Aikido.Slice.Instance, as: SliceInstance
  alias Spark.Dsl.Transformer

  @impl true
  def after?(Aikido.Ash.Transformers.Agent), do: true
  def after?(_), do: false

  @impl Spark.Dsl.Transformer
  def transform(dsl_state) do
    native? = Aikido.Ash.Agent in Spark.extensions(dsl_state)

    user_mounts =
      if native?,
        do:
          Enum.filter(Transformer.get_entities(dsl_state, [:agent]), &match?(%SliceMount{}, &1)),
        else: Transformer.get_entities(dsl_state, [:slices])

    user_middleware =
      if native?,
        do: Transformer.get_option(dsl_state, [:agent], :middleware, []),
        else: Transformer.get_persisted(dsl_state, :aikido_user_middleware, [])

    default_slice_list = if native?, do: [], else: resolve_default_slices(dsl_state)

    slice_instances_from_user = Enum.map(user_mounts, &classify_mount(&1, dsl_state))

    default_slice_instances =
      Enum.map(default_slice_list, &normalize_default_slice/1)

    slice_instances = default_slice_instances ++ slice_instances_from_user

    middleware_list = Enum.map(user_middleware, &normalize_middleware!/1)

    slice_paths = Enum.map(slice_instances, & &1.path)

    agent_path = Spark.Dsl.Extension.get_opt(dsl_state, [:agent], :path)

    agent_routes =
      Transformer.get_persisted(
        dsl_state,
        :aikido_agent_routes,
        Transformer.get_entities(dsl_state, [:signal_routes])
      )

    slice_paths_for_action =
      build_action_path_table(slice_instances, agent_routes, agent_path)

    dsl_state =
      dsl_state
      |> Transformer.persist(:slice_instances, slice_instances)
      |> Transformer.persist(:middleware_list, middleware_list)
      |> Transformer.persist(:slice_paths, slice_paths)
      |> Transformer.persist(:slice_paths_for_action, slice_paths_for_action)

    {:ok, dsl_state}
  end

  defp resolve_default_slices(dsl_state) do
    aikido_module = Transformer.get_persisted(dsl_state, :aikido_instance_module)
    default_slices_override = Transformer.get_persisted(dsl_state, :default_slices_override)

    base_defaults = Aikido.Agent.DefaultSlices.for_instance(aikido_module)

    Aikido.Agent.DefaultSlices.apply_agent_overrides(base_defaults, default_slices_override)
  end

  defp normalize_default_slice(entry) do
    path = Aikido.Agent.DefaultSlices.path_of(entry)
    module = Aikido.Agent.DefaultSlices.module_of(entry)
    config = Aikido.Agent.DefaultSlices.config_of(entry)
    ensure_module_loaded!(module)
    SliceInstance.new({module, config}, path)
  end

  defp normalize_middleware!(module) when is_atom(module), do: {module, %{}}

  defp normalize_middleware!({module, opts}) when is_atom(module),
    do: {module, normalize_to_map(opts)}

  defp normalize_middleware!(other) do
    raise CompileError,
      description:
        "Invalid middleware entry: #{inspect(other)}. Expected a module or `{Module, opts}`."
  end

  defp classify_mount(%SliceMount{path: path, module: module, options: options}, dsl_state) do
    ensure_module_loaded!(module)

    native_slice? =
      Spark.Dsl.is?(module, Ash.Resource) && Aikido.Ash.Slice in Spark.extensions(module)

    unless native_slice? ||
             (Spark.Dsl.is?(module, Ash.Resource) && Aikido.Dsl.Slice in Spark.extensions(module)) do
      raise CompileError,
        description:
          "Module #{inspect(module)} mounted in `slices do …` is not a " <>
            "slice resource using `Aikido.Ash.Slice` or a `use Aikido.Slice` module."
    end

    block_config = read_contributed_block(module, dsl_state)
    config = Map.merge(normalize_to_map(options), block_config)

    SliceInstance.new({module, config}, path)
  end

  defp read_contributed_block(module, dsl_state) do
    contributed_sections =
      Transformer.get_persisted(dsl_state, :aikido_contributed_sections, %{})

    case Map.get(contributed_sections, module) do
      nil ->
        %{}

      section_name ->
        dsl_state
        |> Map.get([section_name], Spark.Dsl.Extension.default_section_config())
        |> Map.get(:opts)
        |> Kernel.||([])
        |> Map.new()
    end
  end

  defp ensure_module_loaded!(module) do
    with {:module, _} <- Code.ensure_compiled(module),
         {:module, _} <- Code.ensure_loaded(module) do
      :ok
    else
      {:error, reason} ->
        raise CompileError,
          description: "Module #{inspect(module)} could not be compiled: #{inspect(reason)}"
    end
  end

  defp normalize_to_map(opts) when is_map(opts), do: opts
  defp normalize_to_map(opts) when is_list(opts), do: Map.new(opts)

  defp build_action_path_table(slice_instances, agent_routes, agent_path) do
    pairs =
      Enum.flat_map(slice_instances, fn %SliceInstance{module: module, path: path} ->
        Enum.map(SliceInfo.actions(module), &{&1, path})
      end) ++
        agent_route_pairs(agent_routes, agent_path)

    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {action, paths} -> {action, Enum.uniq(paths)} end)
  end

  defp agent_route_pairs(_routes, nil), do: []

  defp agent_route_pairs(routes, agent_path) when is_atom(agent_path) do
    Enum.flat_map(routes, fn
      %Aikido.Dsl.Agent.Route{action: action} when not is_nil(action) ->
        [{action, agent_path}]

      _ ->
        []
    end)
  end
end
