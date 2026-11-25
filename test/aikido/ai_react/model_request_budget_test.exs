defmodule Aikido.ModelRequestBudgetTest do
  use ExUnit.Case, async: true
  alias Aikido.AiReact.ModelRequestBudget
  alias Aikido.AttemptTimingTest.Manual

  setup do
    clock = start_supervised!({Manual, self()})
    %{clock: clock, timing: {Manual, clock}}
  end

  test "preparation consumes the captured attempt budget and caller limits remain shorter", ctx do
    budget = ModelRequestBudget.deadline(ctx.timing, nil, 100)
    :ok = Manual.advance(ctx.clock, 35)

    assert {:ok, opts} =
             ModelRequestBudget.options(
               [
                 total_timeout: 50,
                 receive_timeout: :infinity,
                 req_http_options: [finch: [pool_timeout: 10]],
                 max_retries: 3
               ],
               ctx.timing,
               budget
             )

    assert opts[:total_timeout] == 50
    assert opts[:receive_timeout] == 65
    assert opts[:req_http_options][:finch][:pool_timeout] == 10
    assert opts[:max_retries] == 3
    :ok = Manual.advance(ctx.clock, 100)

    assert {:error, %Aikido.AiReact.Errors.ModelTimeout{kind: :attempt, timeout: 100}} =
             ModelRequestBudget.options([], ctx.timing, budget)
  end

  test "each outer attempt re-evaluates the same inherited deadline", ctx do
    deadline = Manual.system_ms(ctx.clock) + 150
    first = ModelRequestBudget.deadline(ctx.timing, deadline, 100)
    assert {:ok, opts} = ModelRequestBudget.options([], ctx.timing, first)
    assert opts[:total_timeout] == 100
    :ok = Manual.advance(ctx.clock, 120)
    next = ModelRequestBudget.deadline(ctx.timing, deadline, 100)
    assert {:ok, opts} = ModelRequestBudget.options([], ctx.timing, next)
    assert opts[:total_timeout] == 30
    :ok = Manual.advance(ctx.clock, 150)

    assert {:error, %Aikido.AiReact.Errors.ModelTimeout{kind: :deadline, timeout: 30}} =
             ModelRequestBudget.options([], ctx.timing, next)
  end

  test "invalid caller options remain subject to native provider validation", ctx do
    budget = ModelRequestBudget.deadline(ctx.timing, nil, 100)

    assert {:ok, opts} =
             ModelRequestBudget.options(
               [receive_timeout: "invalid", req_http_options: [finch: [pool_timeout: -1]]],
               ctx.timing,
               budget
             )

    assert opts[:receive_timeout] == "invalid"
    assert opts[:req_http_options][:finch][:pool_timeout] == -1
  end

  test "bounded options work through the native ReqLLM provider and Req adapter", ctx do
    observer = self()

    adapter = fn request ->
      send(observer, {:native_adapter_options, request.options})

      body = %{
        "id" => "synthetic",
        "model" => "gpt-4o-mini",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "done"},
            "finish_reason" => "stop"
          }
        ]
      }

      {request, Req.Response.new(status: 200, body: body)}
    end

    budget = ModelRequestBudget.deadline(ctx.timing, nil, 100)

    assert {:ok, options} =
             ModelRequestBudget.options(
               [api_key: "synthetic-test-only", req_http_options: [adapter: adapter]],
               ctx.timing,
               budget
             )

    assert {:ok, response} = ReqLLM.Generation.generate_text("openai:gpt-4o-mini", "hi", options)
    assert %ReqLLM.Response{} = response
    assert_receive {:native_adapter_options, %{receive_timeout: 100}}, 5_000
  end
end
