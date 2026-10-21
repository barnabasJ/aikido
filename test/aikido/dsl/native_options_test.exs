defmodule AikidoTest.NativeOptions.Extension do
  @section %Spark.Dsl.Section{
    name: :custom_options,
    schema: [label: [type: :string, required: true]]
  }
  use Spark.Dsl.Extension, sections: [@section]
end

defmodule AikidoTest.NativeOptions.Agent do
  use Aikido.Agent,
    domain: AikidoTest.NativeOptions.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AikidoTest.NativeOptions.Extension]

  agent do
    name "native_options"
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  custom_options do
    label("agent")
  end
end

defmodule AikidoTest.NativeOptions.Slice do
  use Aikido.Slice,
    domain: AikidoTest.NativeOptions.Domain,
    extensions: [AikidoTest.NativeOptions.Extension]

  slice do
    name "native_options"
  end

  custom_options do
    label("slice")
  end
end

defmodule AikidoTest.NativeOptions.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension], validate_config_inclusion?: false

  agents do
    agent :configured, AikidoTest.NativeOptions.Agent
  end
end

defmodule AikidoTest.NativeOptions.Instance do
  use Aikido, otp_app: :aikido, extensions: [AikidoTest.NativeOptions.Extension]

  custom_options do
    label("instance")
  end
end

defmodule AikidoTest.NativeOptions.Directive do
  use Aikido.Directive, extensions: [AikidoTest.NativeOptions.Extension]

  typed_struct do
    field :value, :integer do
      description "Domain value used to verify state transitions and native contracts."
      default 1
    end
  end

  custom_options do
    label("directive")
  end

  @impl true
  def exec(_, _, _), do: :ok
end

defmodule AikidoTest.NativeOptionsTest do
  use ExUnit.Case, async: true

  test "agent convenience host preserves domain, data layer, authorization and extra extensions" do
    resource = AikidoTest.NativeOptions.Agent
    assert Ash.Resource.Info.domain(resource) == AikidoTest.NativeOptions.Domain
    assert Ash.DataLayer.data_layer(resource) == Ash.DataLayer.Ets
    assert Ash.Resource.Info.authorizers(resource) == [Ash.Policy.Authorizer]
    assert Aikido.Agent.Extension in Spark.extensions(resource)
    assert Spark.Dsl.Extension.get_opt(resource, [:custom_options], :label) == "agent"

    input = Ash.ActionInput.for_action(resource, :start, %{})
    refute Ash.can?(input, nil)
    assert Ash.can?(input, %{id: "actor"})
  end

  test "slice convenience host preserves the caller domain and merges its required extension" do
    resource = AikidoTest.NativeOptions.Slice
    assert Ash.Resource.Info.domain(resource) == AikidoTest.NativeOptions.Domain
    assert Ash.Resource.Info.embedded?(resource)
    assert Aikido.Slice.Extension in Spark.extensions(resource)
    assert Spark.Dsl.Extension.get_opt(resource, [:custom_options], :label) == "slice"
  end

  test "instance and directive hosts preserve custom Spark extensions and their own DSL" do
    instance = AikidoTest.NativeOptions.Instance
    assert Aikido.Instance.Info.instance_options(instance).otp_app == :aikido
    assert Spark.Dsl.Extension.get_opt(instance, [:custom_options], :label) == "instance"

    directive = AikidoTest.NativeOptions.Directive
    assert directive.new!(value: "2").value == 2
    assert Spark.Dsl.Extension.get_opt(directive, [:custom_options], :label) == "directive"
  end

  test "the default domain remains an ordinary permissive Ash domain" do
    assert Ash.Resource.Info.domain(AikidoTest.TestAgents.Minimal) == Aikido.RuntimeDomain
    assert Ash.Domain.Info.allow_unregistered?(Aikido.RuntimeDomain)
  end

  test "an explicit strict domain retains native resource inclusion warnings" do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AikidoTest.NativeOptions.Unregistered do
          use Aikido.Agent, domain: AikidoTest.NativeOptions.Domain
          agent do
            name "unregistered"
          end
        end
        """)
      end)

    assert stderr =~
             "AikidoTest.NativeOptions.Unregistered is not present in any known Ash.Domain"
  end
end
