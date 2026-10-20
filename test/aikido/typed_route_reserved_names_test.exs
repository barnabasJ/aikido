defmodule AikidoTest.TypedRouteReservedNamesTest.Noop do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
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
        resource(:agent, "signal :launch, #{inspect(definition)}, #{inspect(Noop)}")

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
        resource(:agent, "signal :start, #{inspect(definition)}, #{inspect(Noop)}")
      end
    end
  end

  test "public signal names cannot replace internal initialization when the handler differs" do
    definition = definition!(:add)

    for name <- [:initialize, :__aikido_initialize_state__] do
      {resource, errors} =
        resource(:agent, "signal #{inspect(name)}, #{inspect(definition)}, #{inspect(Noop)}")

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
      resource(:agent, "route \"app.inspect\", :inspect", """
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
    assert Spark.Dsl.Extension.get_persisted(resource, :aikido_generated_handlers, %{}) == %{}
  end

  test "ordinary typed slices retain their native create defaults and update action" do
    definition = definition!(:increment)

    {resource, errors} =
      resource(:slice, """
      schema do
        attribute :count, :integer, default: 7, allow_nil?: false
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
      def run(input, _, _), do: Aikido.Types.ActionResult.new(state: input.arguments.state)
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
