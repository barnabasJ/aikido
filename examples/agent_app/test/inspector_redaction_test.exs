defmodule AgentExamples.InspectorRedactionTest do
  use ExUnit.Case, async: true
  alias Aikido.Inspector.History, as: Inspector

  defmodule PreserveState do
    use Ash.Resource.Actions.Implementation

    @impl true
    def run(input, _opts, _context) do
      Aikido.Types.ActionResult.new(state: input.arguments.state)
    end
  end

  defmodule Details do
    use Ash.Resource, data_layer: :embedded

    actions do
      defaults create: [:ordinary, :visible]
    end

    attributes do
      attribute :ordinary, :string do
        description "Sensitive content whose name is not a credential hint."
        sensitive? true
      end

      attribute :visible, :string do
        description "Public content retained by the projection."
      end
    end
  end

  defmodule Vault do
    use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Slice.Extension]

    slice do
      name "inspector_vault"

      schema do
        attribute :ordinary, :string do
          description "Sensitive mounted state."
          sensitive? true
        end
      end
    end
  end

  defmodule Submitted do
    use Aikido.Signal

    signal do
      type "inspector.submitted"

      schema do
        attribute :ordinary, :string do
          description "Sensitive signal argument."
          sensitive? true
        end

        attribute :details, {:array, Details} do
          description "Nested resource values in a typed signal."
        end
      end
    end
  end

  defmodule Agent do
    use Aikido.Agent

    agent do
      name "inspector_redaction"
      path :local

      schema do
        attribute :ordinary, :string do
          description "Sensitive own-state attribute."
          sensitive? true
        end

        attribute :details, {:array, Details} do
          description "Nested embedded resource values."
        end
      end

      slice :vault, Vault
      route Submitted, AgentExamples.InspectorRedactionTest.PreserveState, public?: false
      route "inspector.native", :native, public?: false
      route "inspector.whole", :whole, public?: false
    end

    actions do
      action :whole, Aikido.Types.ActionResult do
        argument :state, :map do
          description "State passed to the explicit native reducer."
        end

        argument :data, :map do
          description "Sensitive whole-payload contract."
          sensitive? true
        end

        run AgentExamples.InspectorRedactionTest.PreserveState
      end

      action :native, Aikido.Types.ActionResult do
        argument :state, :map do
          description "State passed to the explicit native reducer contract."
        end

        argument :ordinary, :string do
          sensitive? true
        end

        run AgentExamples.InspectorRedactionTest.PreserveState
      end
    end
  end

  test "own state, embedded arrays and mounted slices honor sensitive metadata before history is stored" do
    agent =
      Agent.initialize!(%{
        state: %{
          local: %{
            ordinary: "own-value",
            details: [%{ordinary: "nested-value", visible: "shown"}]
          },
          vault: %{ordinary: "slice-value"}
        }
      })

    projected =
      Inspector.project_agent_state(agent.state, Agent)

    assert projected["local"]["ordinary"] == "[redacted]"
    assert projected["vault"]["ordinary"] == "[redacted]"
    assert [%{"ordinary" => "[redacted]", "visible" => "shown"}] = projected["local"]["details"]
    refute Jason.encode!(projected) =~ "value"
  end

  test "typed signals and explicit native action arguments redact sensitive values" do
    for type <- ["inspector.submitted", "inspector.native"] do
      projected =
        Inspector.project_event(
          %{
            signal: %Aikido.Signal{
              type: type,
              data: %{
                "ordinary" => "signal-value",
                "details" => [%{ordinary: "nested-value", visible: "shown"}]
              }
            },
            directives: [],
            error: nil
          },
          Agent
        )

      assert projected.signal.data["ordinary"] == "[redacted]"

      if type == "inspector.submitted" do
        assert [%{"ordinary" => "[redacted]", "visible" => "shown"}] =
                 projected.signal.data["details"]

        refute Jason.encode!(projected) =~ "nested-value"
      end

      refute Jason.encode!(projected) =~ "signal-value"
    end
  end

  test "resource structs retain their schema inside arbitrary collections" do
    projected =
      Inspector.project_state(%{
        items: [Ash.create!(Details, %{ordinary: "struct-value", visible: "shown"})]
      })

    assert [%{"ordinary" => "[redacted]", "visible" => "shown"}] = projected["items"]

    projected_directive =
      Inspector.project_event(%{
        signal: %Aikido.Signal{type: "untyped", data: %{}},
        error: nil,
        directives: [
          %Aikido.Directives.AsyncTask{
            work: fn -> :ok end,
            payload: %{
              record: Ash.create!(Details, %{ordinary: "directive-value", visible: "shown"})
            }
          }
        ]
      })

    refute Jason.encode!(projected_directive) =~ "directive-value"
  end

  test "native whole-payload sensitivity redacts the entire signal data" do
    projected =
      Inspector.project_event(
        %{
          signal: %Aikido.Signal{type: "inspector.whole", data: %{ordinary: "whole-value"}},
          directives: [],
          error: nil
        },
        Agent
      )

    assert projected.signal.data == "[redacted]"
    refute Jason.encode!(projected) =~ "whole-value"
  end

  test "sensitive argument values are also removed from error details and explanations" do
    secret = "private-invalid-value"

    error =
      Ash.Error.Changes.InvalidAttribute.exception(
        field: :ordinary,
        value: secret,
        message: "is invalid"
      )

    projected =
      Inspector.project_event(
        %{
          signal: %Aikido.Signal{type: "inspector.submitted", data: %{ordinary: secret}},
          directives: [],
          error: Ash.Error.to_error_class(error)
        },
        Agent
      )

    refute Jason.encode!(projected) =~ secret
    assert projected.error_message =~ "[redacted]"
  end

  test "long typed collections retain thirty redacted entries and a truncation marker" do
    projected =
      Inspector.project_agent_state(
        %{
          local: %{details: List.duplicate(%{ordinary: "secret-value", visible: "shown"}, 10_000)}
        },
        Agent
      )

    details = projected["local"]["details"]
    assert length(details) == 31
    assert List.last(details) == "[list truncated]"
    assert Enum.all?(Enum.take(details, 30), &(&1["ordinary"] == "[redacted]"))
    refute Jason.encode!(projected) =~ "secret-value"
  end

  test "large snapshots remain bounded nested data rather than a JSON preview string" do
    state = %{
      ai: Map.new(1..60, &{"field_#{&1}", String.duplicate("large ", 1000)}),
      team: %{members: %{worker: "running"}}
    }

    projected = Inspector.project_state(state)
    assert is_map(projected["ai"])
    assert map_size(projected["ai"]) == 60
    assert projected["team"]["members"]["worker"] == "running"
    assert byte_size(Jason.encode!(projected)) <= 32_768
    refute Map.has_key?(projected, "preview")
    assert Jason.encode!(projected) =~ "truncated"
  end
end
