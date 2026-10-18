defmodule Aikido.AgentServer.Options do
  @moduledoc """
  Options for starting an AgentServer.

  > #### Internal Module {: .warning}
  > This module is internal to the AgentServer implementation. Its API may
  > change without notice.

  Validates and normalizes startup options including agent configuration,
  hierarchy settings, middleware chain, and dispatch configuration.
  """

  alias Aikido.AgentServer.ParentRef

  @type on_parent_death :: :stop | :continue | :emit_orphan

  use Ash.TypedStruct

  typed_struct do
    field :agent_module, :atom,
      allow_nil?: false,
      description: "Agent module; required. Always constructed via new/1."

    field :aikido, :atom,
      allow_nil?: true,
      description: "Aikido instance name for registry scoping (default: Aikido)"

    field :partition, :term,
      allow_nil?: true,
      description: "Logical partition within a Aikido instance"

    field :id, :string,
      allow_nil?: true,
      description: "Instance ID (auto-generated if not provided)",
      constraints: [trim?: false, allow_empty?: true]

    field :initial_state, :map,
      allow_nil?: false,
      default: %{},
      description: "Initial agent state"

    field :registry, :atom,
      allow_nil?: false,
      default: Aikido.Registry,
      description: "Registry module"

    field :register_global, :boolean,
      allow_nil?: false,
      default: true,
      description: "Register agent id in :registry during init"

    field :default_dispatch, :term,
      allow_nil?: true,
      description: "Default dispatch config for Emit directives"

    field :middleware, {:array, :term},
      allow_nil?: false,
      default: [],
      description:
        "Runtime-appended middleware modules. Each entry is a bare module or {Mod, opts_map}."

    field :parent, :term, allow_nil?: true, description: "Parent reference for hierarchy"

    field :on_parent_death, :atom,
      allow_nil?: false,
      default: :stop,
      description: "Behavior when parent dies"

    field :spawn_fun, :term,
      allow_nil?: true,
      description: "Custom function for spawning children"

    field :skip_schedules, :boolean,
      allow_nil?: false,
      default: false,
      description: "Skip registering plugin schedules (useful for tests)"

    field :pool, :atom,
      allow_nil?: true,
      description: "Manager name if started via Aikido.Durable"

    field :pool_key, :term,
      allow_nil?: true,
      description: "Manager key if started via Aikido.Durable"

    field :debug, :boolean,
      allow_nil?: false,
      default: false,
      description: "Enable debug mode with event buffer"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc false
  @spec schema() :: Ash.Type.t()
  def schema, do: @schema

  @doc """
  Creates validated Options from a keyword list or map.

  Normalizes and validates all options, including:
  - Generating an ID if not provided
  - Validating the agent module
  - Parsing parent reference

  Returns `{:ok, options}` or `{:error, reason}`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    opts |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, agent_module} <- validate_agent_module(attrs[:agent_module]),
         {:ok, parent} <- validate_parent(attrs[:parent]) do
      attrs =
        attrs
        |> Map.put(:agent_module, agent_module)
        |> Map.put(:parent, parent)

      super(attrs)
    end
  end

  def new(_),
    do: {:error, Aikido.Error.validation_error("Options requires a keyword list or map")}

  @doc """
  Creates validated Options from a keyword list or map, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, options} -> options
      {:error, reason} -> raise Aikido.Error.validation_error("Invalid Options", details: reason)
    end
  end

  # Normalize attributes with defaults
  defp normalize_attrs(attrs) do
    id =
      case Map.get(attrs, :id) do
        nil -> Aikido.Util.generate_id()
        "" -> Aikido.Util.generate_id()
        id when is_binary(id) -> id
        id when is_atom(id) -> Atom.to_string(id)
      end

    partition = Map.get(attrs, :partition)

    aikido_instance = Map.get(attrs, :aikido, Aikido)
    registry = Map.get(attrs, :registry, Aikido.registry_name(aikido_instance))
    attrs = Map.put(attrs, :aikido, aikido_instance)

    attrs
    |> Map.put(:id, id)
    |> Map.put(:partition, partition)
    |> Map.put(:registry, registry)
  end

  defp validate_agent_module(nil),
    do: {:error, Aikido.Error.validation_error("agent_module is required")}

  defp validate_agent_module(mod) when is_atom(mod) do
    case Code.ensure_loaded(mod) do
      {:module, _} ->
        if function_exported?(mod, :new, 0) or function_exported?(mod, :new, 1) do
          {:ok, mod}
        else
          {:error, Aikido.Error.validation_error("agent_module must implement new/0 or new/1")}
        end

      {:error, _} ->
        {:error, Aikido.Error.validation_error("agent_module not found: #{inspect(mod)}")}
    end
  end

  defp validate_agent_module(_),
    do: {:error, Aikido.Error.validation_error("agent_module must be a module atom")}

  defp validate_parent(nil), do: {:ok, nil}

  defp validate_parent(%ParentRef{} = parent), do: {:ok, parent}

  defp validate_parent(attrs) when is_map(attrs) do
    ParentRef.new(attrs)
  end

  defp validate_parent(_) do
    {:error, Aikido.Error.validation_error("parent must be nil or a ParentRef")}
  end
end
