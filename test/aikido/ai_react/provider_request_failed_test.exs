defmodule Aikido.ProviderRequestFailedTest do
  use ExUnit.Case, async: true

  alias Aikido.AiReact.Errors.ProviderRequestFailed

  test "public conversion retains identifier-shaped parameter names from raw and nested errors" do
    for name <- [:model, "max_tokens", String.duplicate("p", 64)] do
      raw =
        ReqLLM.Error.Invalid.Parameter.exception(
          parameter: name,
          vars: [value: "PRIVATE-VALUE-OR-BODY", response_body: "PRIVATE-VALUE-OR-BODY"]
        )

      nested = ReqLLM.Error.Invalid.exception(errors: [raw])
      outer = ReqLLM.Error.API.exception(errors: [nested])

      for reason <- [raw, nested, outer] do
        error = ProviderRequestFailed.from_reason(reason)
        assert error.cause_type == ReqLLM.Error.Invalid.Parameter
        assert Map.get(error, :parameter) == to_string(name)
        assert Exception.message(error) =~ "Parameter: #{name}."
        assert AshLua.Error.to_error(error).vars.parameter == to_string(name)
        refute inspect(error, limit: :infinity) =~ "PRIVATE-VALUE-OR-BODY"
        refute Exception.message(error) =~ "PRIVATE-VALUE-OR-BODY"
      end
    end
  end

  test "malformed and oversized parameter names omit private data from every public surface" do
    private = "PRIVATE-VALUE-OR-BODY"

    for name <- [
          nil,
          "",
          " model",
          "model ",
          "model\n",
          "model=value",
          "Invalid parameter: #{private}",
          "provider_options[:auth_mode]",
          String.duplicate("p", 65),
          "pаrameter",
          123,
          true,
          false,
          %{value: private},
          [private],
          self()
        ] do
      raw =
        ReqLLM.Error.Invalid.Parameter.exception(
          parameter: name,
          vars: [value: private, response_body: private, headers: %{authorization: private}]
        )

      for reason <- [raw, ReqLLM.Error.Invalid.exception(errors: [raw])] do
        error = ProviderRequestFailed.from_reason(reason)
        assert error.cause_type == ReqLLM.Error.Invalid.Parameter
        assert Map.get(error, :parameter) == nil
        refute Map.has_key?(AshLua.Error.to_error(error).vars, :parameter)
        refute inspect(error, limit: :infinity) =~ private
        refute Exception.message(error) =~ private
        refute AshAi.ToToolError.to_tool_error(error) =~ private
        refute inspect(AshLua.Error.to_error(error), limit: :infinity) =~ private
      end
    end
  end

  test "actual HTTP and timeout causes keep their existing typed details and guidance" do
    private = "PRIVATE-RESPONSE-BODY"

    for status <- [200, 401, 429, 503] do
      error =
        ReqLLM.Error.API.Response.exception(
          status: status,
          reason: private,
          response_body: %{secret: private}
        )
        |> ProviderRequestFailed.from_reason()

      assert error.cause_type == ReqLLM.Error.API.Response
      assert error.status == status
      assert Map.get(error, :parameter) == nil
      assert Exception.message(error) =~ "HTTP #{status}"
      refute inspect(error, limit: :infinity) =~ private
      refute Exception.message(error) =~ private
    end

    error =
      ReqLLM.Error.API.Timeout.exception(kind: :receive, timeout: 20_000)
      |> ProviderRequestFailed.from_reason()

    assert error.timeout_phase == :receive
    assert error.timeout_ms == 20_000
    assert ProviderRequestFailed.code(error) == "provider_timeout"
    assert Exception.message(error) =~ "20000ms (receive)"
    assert Map.get(error, :parameter) == nil
  end

  test "unknown reasons and already normalized application errors pass through unchanged" do
    for reason <- [
          :timeout,
          {:unknown, %{private: "private"}},
          %{unknown: "value"},
          "application-authored",
          RuntimeError.exception("application failure"),
          ProviderRequestFailed.exception(status: 429)
        ] do
      assert ProviderRequestFailed.from_reason(reason) === reason
    end
  end
end
