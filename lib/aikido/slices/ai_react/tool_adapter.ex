defmodule Aikido.Slices.AiReact.ToolAdapter do
  @moduledoc """
  Adapts Aikido Actions into ReqLLM.Tool structs for LLM consumption.

  This module bridges Aikido domain concepts (actions with schemas) to ReqLLM's
  tool representation.

  ## Design

  - **Schema-focused**: Tools use a noop callback; Aikido owns execution via `Aikido.Exec.run/4`
  - **Adapter pattern**: Converts `Aikido.Action` behaviour → `ReqLLM.Tool` struct
  - **Single source of truth**: All action→tool conversion goes through this module

  ## Usage

      # Convert action modules to ReqLLM tools
      tools = Aikido.Slices.AiReact.ToolAdapter.from_actions([
        MyApp.Actions.Calculator,
        MyApp.Actions.Search
      ])

      # With options
      tools = Aikido.Slices.AiReact.ToolAdapter.from_actions(actions,
        prefix: "myapp_",
        filter: fn mod -> Aikido.Dsl.Action.Info.category(mod) == :search end
      )

      # Use in LLM call
      ReqLLM.Generation.generate_text(model, context, tools: tools)
  """

  alias Aikido.Action.Schema, as: ActionSchema

  # ============================================================================
  # Action Conversion
  # ============================================================================

  @doc """
  Converts a list of Aikido.Action modules into ReqLLM.Tool structs.

  The returned tools use a noop callback—they're purely for describing available
  actions to the LLM. Actual execution happens via `Aikido.Exec.run/4`.

  ## Arguments

    * `action_modules` - List of modules implementing the `Aikido.Action` behaviour
    * `opts` - Optional keyword list of options

  ## Options

    * `:prefix` - String prefix to add to all tool names (e.g., `"myapp_"`)
    * `:filter` - Function `(module -> boolean)` to filter which actions to include
    * `:strict` - Whether to enable strict mode on the tools. When not set,
      auto-detects based on each action's `strict?/0` callback (defaults to `false`).

  ## Returns

    A list of `ReqLLM.Tool` structs

  ## Examples

      # Basic usage
      tools = Aikido.Slices.AiReact.ToolAdapter.from_actions([MyApp.Actions.Add, MyApp.Actions.Search])

      # With prefix
      tools = Aikido.Slices.AiReact.ToolAdapter.from_actions(actions, prefix: "calc_")
      # Tool names become "calc_add", "calc_search", etc.

      # With filter
      tools = Aikido.Slices.AiReact.ToolAdapter.from_actions(actions,
        filter: fn mod -> Aikido.Dsl.Action.Info.category(mod) == :math end
      )
  """
  @type action ::
          module()
          | {module(), atom()}
          | ReqLLM.Tool.t()
          | {ReqLLM.Tool.t(), (map(), map() -> term())}

  @spec from_actions([action()], keyword()) :: [ReqLLM.Tool.t()]
  def from_actions(action_modules, opts \\ [])

  def from_actions(action_modules, opts) when is_list(action_modules) do
    prefix = Keyword.get(opts, :prefix)
    filter_fn = Keyword.get(opts, :filter)
    explicit_strict = Keyword.fetch(opts, :strict)

    tools =
      action_modules
      |> maybe_filter(filter_fn)
      |> Enum.map(fn module ->
        strict =
          case explicit_strict do
            {:ok, val} -> val
            :error -> infer_strict?(module)
          end

        from_action(module, prefix: prefix, strict: strict)
      end)

    # Check for duplicate tool names
    names = Enum.map(tools, & &1.name)
    duplicates = names -- Enum.uniq(names)

    if duplicates != [] do
      raise ArgumentError,
            "Duplicate tool names detected: #{inspect(Enum.uniq(duplicates))}. " <>
              "Each action must have a unique name."
    end

    tools
  end

  @doc """
  Converts a single Aikido.Action module into a ReqLLM.Tool struct.

  ## Arguments

    * `action_module` - A module implementing the `Aikido.Action` behaviour
    * `opts` - Optional keyword list of options

  ## Options

    * `:prefix` - String prefix to add to the tool name (e.g., `"myapp_"`)
    * `:strict` - Whether to enable strict mode on the tool. When not set,
      auto-detects based on the action's `strict?/0` callback (defaults to `false`).

  ## Returns

    A `ReqLLM.Tool` struct

  ## Example

      tool = Aikido.Slices.AiReact.ToolAdapter.from_action(MyApp.Actions.Calculator, prefix: "v2_")
      # => %ReqLLM.Tool{name: "v2_calculator", ...}
  """
  @spec from_action(action(), keyword()) :: ReqLLM.Tool.t()
  def from_action(action_module, opts \\ [])

  def from_action({%ReqLLM.Tool{} = tool, callback}, opts) when is_function(callback, 2),
    do: from_action(tool, opts)

  def from_action(%ReqLLM.Tool{} = tool, opts) do
    %{
      tool
      | name: apply_prefix(tool.name, opts[:prefix]),
        strict: Keyword.get(opts, :strict, tool.strict)
    }
  end

  def from_action({resource, action_name}, opts) do
    {tool, _callback} =
      AshAi.Tools.build(ash_tool({resource, action_name}), Keyword.put_new(opts, :strict, false))

    from_action(tool, opts)
  end

  def from_action(action_module, opts) when is_atom(action_module) do
    prefix = Keyword.get(opts, :prefix)

    strict =
      Keyword.get_lazy(opts, :strict, fn -> infer_strict?(action_module) end)

    ReqLLM.Tool.new!(
      name:
        apply_prefix(Map.get(Aikido.Dsl.Action.Info.action_options(action_module), :name), prefix),
      description: Map.get(Aikido.Dsl.Action.Info.action_options(action_module), :description),
      parameter_schema: build_json_schema(Aikido.Dsl.Action.Info.schema(action_module)),
      callback: &noop_callback/1,
      strict: strict
    )
  end

  @doc false
  def ash_tool({resource, action_name}) do
    action =
      Ash.Resource.Info.action(resource, action_name) ||
        raise ArgumentError, "Unknown Ash action: #{inspect({resource, action_name})}"

    %AshAi.Tool{
      name: action_name,
      resource: resource,
      domain: Ash.Resource.Info.domain(resource),
      action: action,
      arguments: [],
      load: [],
      select: nil
    }
  end

  @doc """
  Normalizes tool input into an action lookup map (`%{name => module}`).

  Accepts any of the common tool container shapes used by actions/skills:

  - `nil` -> `%{}`
  - `%{"tool_name" => MyAction}` -> unchanged
  - `%{tool_name: MyAction}` -> `%{"tool_name" => MyAction}` when values are modules
  - `[MyAction, OtherAction]` -> `%{"my_action" => MyAction, "other_action" => OtherAction}`
  - `MyAction` -> `%{"my_action" => MyAction}`
  """
  @spec to_action_map(nil | map() | [action()] | action()) :: %{String.t() => action()}
  def to_action_map(nil), do: %{}

  def to_action_map(%{} = tools) do
    if Enum.all?(tools, fn {name, mod} -> is_binary(name) and valid_action_module?(mod) end) do
      tools
    else
      tools
      |> Map.values()
      |> to_action_map()
    end
  end

  def to_action_map(modules) when is_list(modules) do
    modules
    |> Enum.filter(&valid_action_module?/1)
    |> Map.new(fn module -> {tool_name(module), module} end)
  end

  def to_action_map(module) when is_atom(module) do
    if valid_action_module?(module) do
      %{Map.get(Aikido.Dsl.Action.Info.action_options(module), :name) => module}
    else
      %{}
    end
  end

  def to_action_map(_), do: %{}

  @doc """
  Looks up an action module by tool name from a list of action modules.

  Useful for finding which action module corresponds to a tool name returned
  by an LLM.

  ## Arguments

    * `tool_name` - The name of the tool to look up
    * `action_modules` - List of action modules to search

  ## Returns

    * `{:ok, module}` - If found
    * `{:error, :not_found}` - If no action module has that tool name

  ## Example

      {:ok, module} = ToolAdapter.lookup_action("calculator", [Calculator, Search])
      # => {:ok, Calculator}

      {:error, :not_found} = ToolAdapter.lookup_action("unknown", [Calculator])
      # => {:error, :not_found}
  """
  @spec lookup_action(String.t(), [action()], keyword()) :: {:ok, action()} | {:error, :not_found}
  def lookup_action(tool_name, action_modules, opts \\ [])

  def lookup_action(tool_name, action_modules, opts)
      when is_binary(tool_name) and is_list(action_modules) do
    prefix = Keyword.get(opts, :prefix)

    case Enum.find(action_modules, fn mod ->
           apply_prefix(tool_name(mod), prefix) == tool_name
         end) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  @doc """
  Validates that all modules in the list implement the Aikido.Action behaviour.

  Returns `:ok` if all modules are valid, or `{:error, {:invalid_action, module, reason}}`
  for the first invalid module found.

  ## Example

      :ok = ToolAdapter.validate_actions([Calculator, Search])
      {:error, {:invalid_action, BadModule, :missing_name}} = ToolAdapter.validate_actions([BadModule])
  """
  @spec validate_actions([action()]) :: :ok | {:error, {:invalid_action, action(), atom()}}
  def validate_actions(action_modules) when is_list(action_modules) do
    Enum.reduce_while(action_modules, :ok, fn module, :ok ->
      case validate_action_module(module) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_action, module, reason}}}
      end
    end)
  end

  defp validate_action_module({%ReqLLM.Tool{}, callback}) when is_function(callback, 2), do: :ok
  defp validate_action_module(%ReqLLM.Tool{}), do: :ok

  defp validate_action_module({resource, name}) when is_atom(resource) and is_atom(name) do
    if match?({:module, _}, Code.ensure_compiled(resource)) &&
         Spark.Dsl.is?(resource, Ash.Resource) &&
         not is_nil(Ash.Resource.Info.action(resource, name)),
       do: :ok,
       else: {:error, :not_an_ash_action}
  end

  defp validate_action_module(module) when is_atom(module) do
    cond do
      not match?({:module, _}, Code.ensure_compiled(module)) -> {:error, :not_loaded}
      not Spark.Dsl.is?(module, Aikido.Action) -> {:error, :not_an_action}
      true -> :ok
    end
  end

  defp validate_action_module(_), do: {:error, :invalid_reference}

  defp valid_action_module?(%ReqLLM.Tool{}), do: true

  defp valid_action_module?({_, _} = tool), do: validate_action_module(tool) == :ok

  defp valid_action_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and Spark.Dsl.is?(module, Aikido.Action)
  end

  defp valid_action_module?(_), do: false

  defp tool_name({%ReqLLM.Tool{name: name}, _callback}), do: name
  defp tool_name(%ReqLLM.Tool{name: name}), do: name
  defp tool_name({_resource, action}), do: to_string(action)
  defp tool_name(module), do: Map.get(Aikido.Dsl.Action.Info.action_options(module), :name)

  # ============================================================================
  # Private Functions - Schema and Filtering
  # ============================================================================

  defp maybe_filter(modules, nil), do: modules

  defp maybe_filter(modules, filter_fn) when is_function(filter_fn, 1) do
    Enum.filter(modules, filter_fn)
  end

  defp build_json_schema(schema), do: ActionSchema.to_json_schema(schema, strict: true)

  # Infers whether an action should use strict mode for LLM tool calling.
  #
  # Checks for a `strict?/0` callback on the action module, defaulting to false.
  # This callback is not part of the Aikido.Action behaviour; it is detected via
  # `function_exported?/3` to keep this adapter decoupled from the action library.
  defp infer_strict?({%ReqLLM.Tool{strict: strict}, _callback}), do: strict
  defp infer_strict?(%ReqLLM.Tool{strict: strict}), do: strict
  defp infer_strict?({_resource, _action}), do: false

  defp infer_strict?(module) do
    if function_exported?(module, :strict?, 0), do: module.strict?(), else: false
  end

  defp noop_callback(_args), do: {:ok, %{}}

  defp apply_prefix(name, nil), do: name
  defp apply_prefix(name, prefix) when is_binary(prefix), do: prefix <> name
end
