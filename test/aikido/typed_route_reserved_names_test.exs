defmodule AikidoTest.TypedRouteReservedNamesTest.Noop do
  use Ash.Resource.Actions.Implementation

  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: nil)
  end
end

defmodule AikidoTest.TypedRouteReservedNamesTest do
  use ExUnit.Case, async: false
  require Spark.Test
  alias AikidoTest.TypedRouteReservedNamesTest.Noop

  @agent_reserved [
    :start,
    :stop,
    :delete,
    :list,
    :inspect,
    :initialize,
    :__aikido_initialize_state__
  ]

  test "generated signal handlers cannot replace agent lifecycle or initialization actions" do
    for name <- @agent_reserved do
      definition = definition!(name)

      {resource, errors} =
        resource(:agent, "route #{inspect(definition)}, #{inspect(Noop)}, public?: false")

      assert_reserved(errors, resource, name, :agent)
    end
  end

  test "generated union and wildcard implementation names cannot replace agent lifecycle" do
    first = definition!(:first)
    second = definition!(:second)
    implementation = implementation!(:stop)

    for route <- [
          "route [#{inspect(first)}, #{inspect(second)}], #{inspect(implementation)}",
          "route \"**\", #{inspect(implementation)}"
        ] do
      {resource, errors} = resource(:agent, route)
      assert_reserved(errors, resource, :stop, :agent)
    end
  end

  test "generated handlers cannot replace native slice create or update actions" do
    for name <- [:create, :update] do
      definition = definition!(name)
      {resource, errors} = resource(:slice, "route #{inspect(definition)}, #{inspect(Noop)}")
      assert_reserved(errors, resource, name, :slice)
    end
  end

  test "generated union and wildcard implementation names cannot replace slice initialization" do
    first = definition!(:first)
    second = definition!(:second)
    implementation = implementation!(:create)

    for route <- [
          "route [#{inspect(first)}, #{inspect(second)}], #{inspect(implementation)}",
          "route \"**\", #{inspect(implementation)}"
        ] do
      {resource, errors} = resource(:slice, route)
      assert_reserved(errors, resource, :create, :slice)
    end
  end

  test "public signal names cannot replace lifecycle even when its handler name differs" do
    for handler <- [:add, :start] do
      definition = definition!(handler)

      assert_raise Spark.Error.DslError, fn ->
        resource(:agent, "route #{inspect(definition)}, #{inspect(Noop)}, name: :start")
      end
    end
  end

  test "public signal names cannot replace internal initialization when the handler differs" do
    definition = definition!(:add)

    for name <- [:initialize, :__aikido_initialize_state__] do
      {resource, errors} =
        resource(:agent, "route #{inspect(definition)}, #{inspect(Noop)}, name: #{inspect(name)}")

      assert Enum.any?(errors, fn
               {^resource, entries} ->
                 Enum.any?(entries, fn
                   %Spark.Error.DslError{path: [:agent], message: message} ->
                     message =~ "Generated public signal #{inspect(name)} is reserved"

                   _ ->
                     false
                 end)

               _ ->
                 false
             end),
             inspect(errors)
    end
  end

  test "application-owned native action contracts remain available" do
    {resource, errors} =
      resource(:agent, "route \"app.inspect\", :inspect, public?: false", """
      actions do
        action :inspect, Aikido.Types.ActionResult do
          public? false
          argument :state, :term
          run #{inspect(Noop)}
        end
      end
      """)

    assert errors == []
    assert Ash.Resource.Info.action(resource, :inspect).run == {Noop, []}

    assert Spark.Dsl.Extension.get_persisted(resource, :aikido_generated_handlers, %{}) == %{
             __aikido_query_children__: Aikido.Ownership.Actions.ReplyChildren,
             __aikido_stop_self__: Aikido.Actions.Lifecycle.StopSelf
           }
  end

  test "runtime defaults do not collide with ordinary action names and explicit routes override them" do
    native_actions = """
    actions do
      for name <- [:stop_self, :query_children] do
        action name, Aikido.Types.ActionResult do
          public? false
          argument :state, :term
          run #{inspect(Noop)}
        end
      end
    end
    """

    {resource, errors} = resource(:agent, "", native_actions)
    assert errors == []
    assert Ash.Resource.Info.action(resource, :stop_self).run == {Noop, []}
    assert Ash.Resource.Info.action(resource, :query_children).run == {Noop, []}
    assert Ash.Resource.Info.action(resource, :__aikido_stop_self__)
    assert Ash.Resource.Info.action(resource, :__aikido_query_children__)

    {override, errors} =
      resource(
        :agent,
        """
        route "aikido.agent.stop", :stop_self, public?: false
        route "aikido.agent.query.children", :query_children, public?: false
        """,
        native_actions
      )

    assert errors == []
    router = Aikido.Signal.Router.new!(Aikido.Agent.Info.signal_routes(override))

    for {type, action} <- [
          {"aikido.agent.stop", :stop_self},
          {"aikido.agent.query.children", :query_children}
        ] do
      assert {:ok, [{^override, ^action}]} =
               Aikido.Signal.Router.route(router, Aikido.Signal.new!(type, %{}))
    end

    refute Ash.Resource.Info.action(override, :__aikido_stop_self__)
    refute Ash.Resource.Info.action(override, :__aikido_query_children__)
  end

  test "a mounted slice owns an explicitly routed system stop" do
    {slice, errors} =
      resource(:slice, """
      route Aikido.AgentServer.Signals.StopSelf, #{inspect(Noop)}, public?: false
      """)

    assert errors == []
    {agent, errors} = resource(:agent, "slice :custom_stop, #{inspect(slice)}")
    assert errors == []
    refute Ash.Resource.Info.action(agent, :__aikido_stop_self__)
    assert Ash.Resource.Info.action(agent, :__aikido_query_children__)

    router =
      Aikido.Signal.Router.new!(
        Aikido.Agent.Info.signal_routes(agent) ++ Aikido.Agent.Info.routes(agent)
      )

    assert {:ok, [{^slice, :stop_self}]} =
             Aikido.Signal.Router.route(router, Aikido.Signal.new!("aikido.agent.stop", %{}))
  end

  test "ordinary typed slices retain their native create defaults and update action" do
    definition = definition!(:increment)

    {resource, errors} =
      resource(:slice, """
      schema do
        attribute :count, :integer do
          description "Current counter value updated by routed signals."
          default 7
          allow_nil? false
        end
      end
      route #{inspect(definition)}, #{inspect(Noop)}
      """)

    assert errors == []
    assert Ash.Resource.Info.action(resource, :create).type == :create
    assert Ash.Resource.Info.action(resource, :update).type == :update
    record = resource |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()
    assert is_struct(record, resource)
    assert record.count == 7
  end

  defp assert_reserved(errors, resource, name, section) do
    assert Enum.any?(errors, fn
             {^resource, entries} ->
               Enum.any?(entries, fn
                 %Spark.Error.DslError{path: [^section], message: message} ->
                   message =~ "Generated reducer action #{inspect(name)} is reserved"

                 _ ->
                   false
               end)

             _ ->
               false
           end),
           inspect(errors)
  end

  defp definition!(name) do
    module = named_module(name)

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Aikido.Signal
      signal do
        type "reserved.#{System.unique_integer([:positive])}"
      end
    end
    """)

    module
  end

  defp implementation!(name) do
    module = named_module(name)

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Ash.Resource.Actions.Implementation
      def run(_input, _, _), do: Aikido.Types.ActionResult.new(changes: nil)
    end
    """)

    module
  end

  defp named_module(name) do
    namespace = Module.concat(__MODULE__, "Definition#{System.unique_integer([:positive])}")

    Module.concat(
      namespace,
      if(String.starts_with?(Atom.to_string(name), "__"),
        do: Atom.to_string(name),
        else: Macro.camelize(Atom.to_string(name))
      )
    )
  end

  defp resource(section, body, additional \\ "") do
    module = Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")
    host = if section == :agent, do: Aikido.Agent, else: Aikido.Slice

    errors =
      Spark.Test.dsl_errors do
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use #{inspect(host)}
          #{section} do
            name "reserved_handler"
            #{body}
          end
          #{additional}
        end
        """)

        module.__verify_spark_dsl__(module)
      end

    {module, errors}
  end
end
