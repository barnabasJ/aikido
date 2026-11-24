defmodule Aikido.Agent.Extension.Transformers.BindRouteMounts do
  @moduledoc "Validates explicitly mounted reducer inputs against the owning slice resource."
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def after?(Aikido.Agent.Extension.Transformers.WalkExtensions), do: true
  def after?(_), do: false

  @impl true
  def before?(Aikido.Agent.Extension.Transformers.ExpandRoutes), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl) do
    routes = Transformer.get_persisted(dsl, :aikido_agent_routes, [])
    mounts = Transformer.get_persisted(dsl, :slice_instances, [])

    with :ok <- validate_routes(dsl, routes, mounts) do
      {:ok, dsl}
    end
  end

  defp validate_routes(dsl, routes, mounts) do
    Enum.reduce_while(routes, :ok, fn route, :ok ->
      with :ok <- validate_mount(dsl, route, mounts),
           :ok <- validate_owner(dsl, route),
           :ok <- validate_distinct_route(dsl, route, mounts) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp validate_distinct_route(_dsl, %{mount: nil}, _mounts), do: :ok

  defp validate_distinct_route(dsl, route, mounts) do
    mount = Enum.find(mounts, &(&1.path == route.mount))

    duplicate? =
      mount.module
      |> Spark.Dsl.Extension.get_entities([:slice])
      |> Enum.any?(fn native ->
        native.type == route.type &&
          Aikido.Slice.Info.action_reference(mount.module, native.action) == route.action
      end)

    if duplicate? do
      error(
        dsl,
        "Route #{inspect(route.type)} duplicates the mounted slice route for #{inspect(route.action)} at #{inspect(route.mount)}; omit the redundant binding to retain the native route"
      )
    else
      :ok
    end
  end

  defp validate_owner(_dsl, %{mount: nil}), do: :ok

  defp validate_owner(dsl, route) do
    paths = Transformer.get_persisted(dsl, :slice_paths_for_action, %{})

    if Map.get(paths, route.action) == [route.mount] do
      :ok
    else
      error(
        dsl,
        "Route action #{inspect(route.action)} has ambiguous mount ownership; an explicitly bound action must target only #{inspect(route.mount)}"
      )
    end
  end

  defp validate_mount(_dsl, %{mount: nil}, _mounts), do: :ok

  defp validate_mount(dsl, route, mounts) do
    case Enum.filter(mounts, &(&1.path == route.mount)) do
      [%{module: resource}] ->
        validate_state_argument(dsl, route, resource)

      _ ->
        error(dsl, "Route mount #{inspect(route.mount)} must identify one declared slice mount")
    end
  end

  defp validate_state_argument(dsl, %{action: {resource, name}} = route, mounted_resource) do
    owner = if resource == Transformer.get_persisted(dsl, :module), do: dsl, else: resource
    action = Ash.Resource.Info.action(owner, name)
    state = if action, do: Enum.find(action.arguments, &(&1.name == :state))

    if state &&
         (state.type == mounted_resource ||
            (Ash.Type.get_type(state.type) == Ash.Type.Struct &&
               state.constraints[:instance_of] == mounted_resource)) do
      :ok
    else
      error(
        dsl,
        "Route action #{inspect(route.action)} bound to #{inspect(route.mount)} requires a :state argument typed as #{inspect(mounted_resource)} or a struct constrained to that resource"
      )
    end
  end

  defp error(dsl, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: Transformer.get_persisted(dsl, :module),
       path: [:agent],
       message: message
     )}
  end
end
