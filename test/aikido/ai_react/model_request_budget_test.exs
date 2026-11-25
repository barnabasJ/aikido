defmodule Aikido.ModelRequestBudgetTest do
  use ExUnit.Case, async: true
  alias Aikido.AiReact.{AttemptBudget, ModelRequestBudget}
  alias Aikido.AttemptTimingTest.Manual

  setup do
    clock = start_supervised!({Manual, self()})
    %{clock: clock, timing: {Manual, clock}}
  end

  test "preparation retains the captured absolute cutoff and native caller options", ctx do
    budget = budget(ctx, 100, 100)
    :ok = Manual.advance(ctx.clock, 35)

    caller = [
      total_timeout: 50,
      receive_timeout: :infinity,
      req_http_options: [finch: [pool_timeout: 10]],
      max_retries: 3
    ]

    assert {:ok, opts} = ModelRequestBudget.options(caller, ctx.timing, budget)
    assert opts[:total_deadline_at] == budget.absolute_deadline_at
    assert Keyword.delete(opts, :total_deadline_at) == caller
    :ok = Manual.advance(ctx.clock, 100)

    assert {:error, %Aikido.AiReact.Errors.ModelTimeout{kind: :attempt, timeout: 100}} =
             ModelRequestBudget.options([], ctx.timing, budget)
  end

  test "each outer attempt retains the same inherited cutoff", ctx do
    deadline = Manual.system_ms(ctx.clock) + 150
    first = budget(ctx, 100, 100, deadline)
    assert {:ok, opts} = ModelRequestBudget.options([], ctx.timing, first)
    assert opts[:total_deadline_at] == deadline - 50
    :ok = Manual.advance(ctx.clock, 120)
    next = budget(ctx, 150, 30, deadline)
    assert {:ok, opts} = ModelRequestBudget.options([], ctx.timing, next)
    assert opts[:total_deadline_at] == deadline
    :ok = Manual.advance(ctx.clock, 150)

    assert {:error, %Aikido.AiReact.Errors.ModelTimeout{kind: :deadline, timeout: 30}} =
             ModelRequestBudget.options([], ctx.timing, next)
  end

  test "a shorter native absolute cutoff is retained and invalid values use native validation",
       ctx do
    budget = budget(ctx, 100, 100)
    shorter = budget.absolute_deadline_at - 30

    assert {:ok, opts} =
             ModelRequestBudget.options([total_deadline_at: shorter], ctx.timing, budget)

    assert opts[:total_deadline_at] == shorter

    assert {:error, %NimbleOptions.ValidationError{}} =
             ModelRequestBudget.options([total_deadline_at: "invalid"], ctx.timing, budget)
  end

  test "other invalid caller options remain subject to native provider validation", ctx do
    budget = budget(ctx, 100, 100)
    caller = [receive_timeout: "invalid", req_http_options: [finch: [pool_timeout: -1]]]
    assert {:ok, opts} = ModelRequestBudget.options(caller, ctx.timing, budget)
    assert Keyword.delete(opts, :total_deadline_at) == caller
  end

  test "the native provider and adapter enforce the carried absolute cutoff" do
    observer = self()

    adapter = fn request ->
      send(
        observer,
        {:native_adapter_options, request.options,
         Req.Request.get_private(request, :req_llm_timeout_deadline)}
      )

      body = %{
        id: "synthetic",
        model: "synthetic",
        choices: [
          %{index: 0, message: %{role: "assistant", content: "done"}, finish_reason: "stop"}
        ]
      }

      {request,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(body)
       )}
    end

    absolute = System.system_time(:millisecond) + 10_000
    monotonic = System.monotonic_time(:millisecond) + 10_000

    budget =
      AttemptBudget.new!(
        monotonic_deadline: monotonic,
        absolute_deadline_at: absolute,
        timeout_ms: 10_000
      )

    assert {:ok, options} =
             ModelRequestBudget.options(
               [api_key: "synthetic-test-only", req_http_options: [adapter: adapter]],
               {Aikido.AiReact.AttemptTiming.System, nil},
               budget
             )

    model =
      ReqLLM.model!(%{
        provider: :openai,
        id: "synthetic",
        extra: %{"wire" => %{"protocol" => "openai_chat"}}
      })

    assert options[:total_deadline_at] == absolute

    assert {:ok, %ReqLLM.Response{} = response} =
             ReqLLM.Generation.generate_text(model, "hi", options)

    assert ReqLLM.Response.text(response) == "done"
    assert_receive {:native_adapter_options, options, native_deadline}, 5_000
    assert options.receive_timeout in 1..10_000
    assert options.finch[:pool_timeout] == options.receive_timeout
    assert options.finch[:request_timeout] == options.receive_timeout
    assert native_deadline.expires_at <= monotonic
  end

  defp budget(ctx, monotonic, timeout, inherited \\ nil) do
    absolute = Manual.system_ms(ctx.clock) + monotonic - Manual.monotonic_ms(ctx.clock)

    AttemptBudget.new!(
      monotonic_deadline: monotonic,
      timeout_ms: timeout,
      absolute_deadline_at: min(absolute, inherited || absolute),
      deadline_at: inherited
    )
  end
end
