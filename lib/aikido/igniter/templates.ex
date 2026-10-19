defmodule Aikido.Igniter.Templates do
  @moduledoc false
  # Template generators for Aikido Igniter mix tasks

  @doc """
  Returns the template for an Agent module.
  """
  @spec agent_template(module :: String.t(), name :: String.t()) :: String.t()
  def agent_template(module, name), do: agent_template(module, name, plugins: [])

  @doc """
  Returns the template for an Agent module with optional plugin attachments.
  """
  @spec agent_template(module :: String.t(), name :: String.t(), opts :: keyword()) :: String.t()
  def agent_template(module, name, opts) do
    plugins = Keyword.get(opts, :plugins, [])
    slices_block = format_slices_block(plugins)

    """
    defmodule #{module} do
      @moduledoc \"\"\"
      TODO: Describe this agent.

      User-domain fields declared in `schema:` live under the agent's
      declared `path:` slice of `agent.state` — e.g. with `path: :domain`,
      a `:counter` field is read as `agent.state.domain.counter`.
      \"\"\"

      use Aikido.Agent

      agent do
        name "#{name}"
        description "TODO: Add description"
        path :domain
        schema do
        end
      end#{slices_block}
    end
    """
  end

  @doc """
  Returns the template for an Agent test module.
  """
  @spec agent_test_template(module :: String.t(), test_module :: String.t()) :: String.t()
  def agent_test_template(module, test_module) do
    alias_name = module_alias(module)

    """
    defmodule #{test_module} do
      use ExUnit.Case, async: true

      alias Aikido.Dsl.Agent.Info, as: AgentInfo
      alias #{module}

      describe "new/1" do
        test "creates agent with default state" do
          agent = #{alias_name}.new()
          assert agent.name == Map.get(AgentInfo.agent_options(#{alias_name}), :name)
        end

        test "creates agent with custom id" do
          agent = #{alias_name}.new(id: "custom-id")
          assert agent.id == "custom-id"
        end
      end
    end
    """
  end

  defp format_slices_block([]), do: ""

  defp format_slices_block(plugins) do
    lines =
      Enum.map_join(plugins, "\n", fn plugin ->
        "    slice :#{slice_path_for(plugin)}, #{inspect(plugin)}"
      end)

    "\n\n  slices do\n#{lines}\n  end"
  end

  defp slice_path_for(plugin) when is_atom(plugin) do
    # Default heuristic: use the plugin's last namespace segment lowercased
    # as the slice path. Users can edit the generated `slice :path, Module`
    # line to assign a different mount path.
    plugin
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp module_alias(module) do
    module
    |> String.split(".")
    |> List.last()
  end
end
