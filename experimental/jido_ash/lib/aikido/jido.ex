defmodule Aikido.Jido do
  @moduledoc """
  Opt-in Ash interfaces for named input routes on a Jido v3 agent.

  Place `use Aikido.Jido` after `use Jido.Agent`. The finalized Jido definition
  supplies the interface; no second route declaration is required. See README.md
  for the pinned upstream contract and current limitations.
  """

  @options [
    domain: [type: :atom, default: Aikido.Jido.Domain],
    authorizers: [type: {:list, :atom}, default: []],
    extensions: [type: {:list, :atom}, default: []]
  ]

  defmacro __using__(opts) do
    opts =
      Macro.prewalk(opts, fn
        {:__aliases__, _, _} = alias_ast -> Macro.expand(alias_ast, __CALLER__)
        node -> node
      end)

    opts = Spark.Options.validate!(opts, @options)

    quote do
      @aikido_jido_options unquote(Macro.escape(opts))
      @before_compile Aikido.Jido
      @after_compile Aikido.Jido
    end
  end

  defmacro __before_compile__(env) do
    # Jido's earlier before_compile callback has built the neutral definition.
    definition = Module.get_attribute(env.module, :agent_definition)

    unless definition do
      raise ArgumentError, "use Aikido.Jido after use Jido.Agent"
    end

    helpers =
      for route <- definition.routes, route.as != nil, mode <- [:call, :cast, :submit, :signal] do
        name = Aikido.Jido.Resource.operation_name(route.as, mode)
        helper = String.to_atom("ash_#{name}")
        resource = Module.concat(env.module, Ash)

        quote do
          def unquote(helper)(params \\ %{}, opts \\ []) do
            apply(unquote(resource), unquote(name), [params, opts])
          end
        end
      end

    quote do
      @doc "Returns the generated Ash resource for this Jido agent."
      def ash_resource, do: Module.concat(__MODULE__, Ash)
      @doc false
      def __aikido_jido_options__, do: @aikido_jido_options
      unquote_splicing(helpers)
    end
  end

  def __after_compile__(env, _bytecode) do
    Aikido.Jido.Resource.build!(env.module, env.module.__aikido_jido_options__(), env)
  end
end
