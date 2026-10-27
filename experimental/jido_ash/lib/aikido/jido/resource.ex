defmodule Aikido.Jido.Resource do
  @moduledoc false

  def operation_name(name, :call), do: name
  def operation_name(name, mode), do: String.to_atom("#{name}_#{mode}")

  def build!(agent, opts, env) do
    resource = Module.concat(agent, Ash)
    routes = agent.definition().routes |> Enum.filter(& &1.as)
    operations = for route <- routes, mode <- [:call, :cast, :submit, :signal], do: {route, mode}
    names = Enum.map(operations, fn {route, mode} -> operation_name(route.as, mode) end)

    if Enum.uniq(names) != names,
      do: raise(ArgumentError, "Jido route names collide with generated Ash operations")

    actions = Enum.map(operations, &action(agent, resource, &1, env))

    interfaces =
      Enum.map(names, fn name -> quote do: define(unquote(name), action: unquote(name)) end)

    body =
      quote do
        use Ash.Resource,
          domain: unquote(opts[:domain]),
          authorizers: unquote(opts[:authorizers]),
          fragments: unquote(opts[:fragments]),
          extensions: unquote(opts[:extensions])

        actions do
          (unquote_splicing(actions))
        end

        code_interface do
          (unquote_splicing(interfaces))
        end
      end

    Module.create(resource, body, Macro.Env.location(env))
  end

  defp action(agent, resource, {route, mode}, env) do
    unless route.handler.kind in [:action, :flow] do
      raise ArgumentError,
            "named #{route.handler.kind} route #{inspect(route.path)} has no executable input schema"
    end

    args = Aikido.Jido.Schema.arguments!(route.handler.target.schema(), route.defaults)
    name = operation_name(route.as, mode)
    implementation = Module.concat([resource, Commands, Macro.camelize(to_string(name))])
    names = Enum.map(args, & &1.name)

    build_implementation(
      implementation,
      agent,
      String.to_atom("#{route.as}_signal"),
      names,
      mode,
      env
    )

    arguments = Enum.map(args, &argument/1)

    runtime_arguments =
      if mode == :signal do
        []
      else
        quote do
          argument :server, :term do
            allow_nil? false
            description "Jido live server address."
          end

          argument :runtime_options, :term do
            default []
            description "Options for the native Jido delivery operation."
          end
        end
        |> List.wrap()
      end

    quote do
      action unquote(name), :term do
        description unquote(
                      "Jido #{mode} for named input #{route.path}; result preserves the native Jido return value."
                    )

        unquote_splicing(arguments)
        unquote_splicing(runtime_arguments)

        argument :signal_options, :term do
          default []
          description "Native Jido input signal envelope options."
        end

        run unquote(implementation)
      end
    end
  end

  defp argument(arg) do
    default =
      case arg.default do
        {:value, {module, function, args} = value}
        when is_atom(module) and is_atom(function) and is_list(args) ->
          quote do: default(fn -> unquote(Macro.escape(value)) end)

        {:value, value} ->
          quote do: default(unquote(Macro.escape(value)))

        nil ->
          nil
      end

    quote do
      argument unquote(arg.name), unquote(Macro.escape(arg.type)) do
        description unquote(arg.description || "Input from the Jido executable Zoi schema.")
        allow_nil? unquote(arg.allow_nil?)
        constraints unquote(Macro.escape(arg.constraints))
        unquote(default)
      end
    end
  end

  defp build_implementation(module, agent, helper, names, mode, env) do
    delivery =
      case mode do
        :signal -> quote do: result
        :call -> quote do: Jido.AgentServer.call(input.arguments.server, signal, options)
        :cast -> quote do: Jido.AgentServer.cast(input.arguments.server, signal, options)
        :submit -> quote do: Jido.AgentServer.submit(input.arguments.server, signal, options)
      end

    body =
      if mode == :signal do
        quote do
          use Ash.Resource.Actions.Implementation
          @impl true
          def run(input, _opts, _context) do
            result =
              Aikido.Jido.Input.signal(input, unquote(agent), unquote(helper), unquote(names))

            {:ok, unquote(delivery)}
          end
        end
      else
        quote do
          use Ash.Resource.Actions.Implementation
          @impl true
          def run(input, _opts, context) do
            result =
              with {:ok, signal} <-
                     Aikido.Jido.Input.signal(
                       input,
                       unquote(agent),
                       unquote(helper),
                       unquote(names)
                     ),
                   {:ok, options} <- Aikido.Jido.Input.runtime_options(input, context) do
                unquote(delivery)
              end

            {:ok, result}
          end
        end
      end

    Module.create(module, body, Macro.Env.location(env))
  end
end
