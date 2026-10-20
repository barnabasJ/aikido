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

  alias Aikido.Slice.Config

  use Ash.TypedStruct

  typed_struct do
    field :module, :atom do
      allow_nil? false
      description "Embedded resource providing this mount's state schema and routed actions."
    end

    field :config, :map do
      allow_nil? false
      default %{}
      description "Validated mount configuration supplied to actions through slice_config."
    end

    field :path, :atom do
      allow_nil? false
      description "The slice key in agent.state"
    end
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
