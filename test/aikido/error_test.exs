defmodule AikidoTest.ErrorTest do
  use ExUnit.Case, async: true
  alias Aikido.Error

  describe "validation_error/2" do
    test "creates a validation error with message" do
      error = Error.validation_error("Invalid input")

      assert %Error.ValidationError{} = error
      assert error.message == "Invalid input"
    end

    test "creates a validation error with field (infers kind: :input)" do
      error = Error.validation_error("Invalid field", field: :email)

      assert error.message == "Invalid field"
      assert error.kind == :input
      assert error.subject == :email
    end

    test "creates a validation error with explicit kind and subject" do
      error = Error.validation_error("Invalid", kind: :config, subject: :timeout)

      assert error.kind == :config
      assert error.subject == :timeout
    end

    test "creates a validation error for action (convenience)" do
      error = Error.validation_error("Action not found", action: SomeAction)

      assert error.message == "Action not found"
      assert error.kind == :action
      assert error.subject == SomeAction
    end
  end

  describe "routing_error/2" do
    test "creates a routing error" do
      error = Error.routing_error("Route not found", target: :agent_1)

      assert %Error.RoutingError{} = error
      assert error.message == "Route not found"
      assert error.target == :agent_1
    end
  end

  test "native input failures are terminal while transient failures remain retryable" do
    refute Error.retryable?(%Ash.Error.Invalid{})
    refute Error.retryable?(%Ash.Error.Forbidden{})
    refute Error.retryable?(Error.validation_error("bad input"))
    refute Error.retryable?(%{retryable?: false})
    assert Error.retryable?(:timeout)
  end
end
