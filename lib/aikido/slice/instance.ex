defmodule Aikido.Slice.Instance do
  @moduledoc """
  Represents a normalized slice instance attached to an agent via the
  agent's declared mount path.

  ## Fields

  - `module` - The embedded Ash resource extended by `Aikido.Ash.Slice`
  - `config` - Resolved config map (validated through configuration contract if
    declared by the slice; otherwise stored verbatim)
  - `path` - The agent-declared mount path
  """

  alias Aikido.Dsl.Slice.Info, as: SliceInfo
  alias Aikido.Slice.Config

  use Ash.TypedStruct

  typed_struct do
    field :module, :atom, allow_nil?: false, description: "The slice module"

    field :config, :map, allow_nil?: false, default: %{}, description: "Resolved configuration"
    field :path, :atom, allow_nil?: false, description: "The slice key in agent.state"
  end

  @type t :: %__MODULE__{}

  @doc """
  Builds an Instance from a slice declaration.

  Accepted shapes:

  - `Module` - bare slice with no config
  - `{Module, %{key: value}}` - slice with map config
  - `{Module, [key: value]}` - slice with keyword config

  Config is resolved through `Aikido.Slice.Config.resolve_config!/2`, which
  merges any `Application.get_env(otp_app, module)` config underneath the
  caller's overrides and validates against the slice's configuration contract if
  one is declared.

  Raises `ArgumentError` when the resolved config fails schema validation.
  """
  @spec new(module() | {module(), map() | keyword()}, atom()) :: t()
  def new(declaration, path) when is_atom(path) and not is_nil(path) do
    {module, overrides} = normalize_declaration(declaration)

    resolved_config = Config.resolve_config!(module, overrides)

    %__MODULE__{
      module: module,
      config: resolved_config,
      path: path
    }
  end

  @doc """
  Expands the slice's signal routes for the agent's combined route table.

  Slice routes use absolute signal types from `Aikido.Dsl.Slice.Info`.
  The output shape is the 3-tuple format `{path, target, opts}` used by
  the agent's route table.
  """
  @spec expand_routes(t()) :: [tuple()]
  def expand_routes(%__MODULE__{module: module}) do
    module
    |> SliceInfo.signal_routes()
    |> Enum.map(&normalize_route/1)
  end

  defp normalize_route({path, match, target, priority}) when is_function(match, 1),
    do: {path, match, target, priority}

  defp normalize_route({path, match, target}) when is_function(match, 1),
    do: {path, match, target, -10}

  defp normalize_route({path, target}), do: {path, target, []}
  defp normalize_route({path, target, opts}) when is_list(opts), do: {path, target, opts}

  defp normalize_route({path, target, priority}) when is_integer(priority) do
    {path, target, [priority: priority]}
  end

  defp normalize_declaration(module) when is_atom(module) do
    {module, %{}}
  end

  defp normalize_declaration({module, overrides}) when is_map(overrides) do
    {module, overrides}
  end

  defp normalize_declaration({module, overrides}) when is_list(overrides) do
    {module, Map.new(overrides)}
  end
end
