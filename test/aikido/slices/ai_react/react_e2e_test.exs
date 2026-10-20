defmodule Aikido.Slices.AiReactE2ETest.NoToolsAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "react_e2e_no_tools"

    slice :ai, Aikido.Slices.AiReact,
      options: [
        model: %{
          provider: :openai,
          id: "google/gemma-4-26b-a4b",
          base_url: "http://localhost:1234/v1"
        },
        tools: [],
        max_iterations: 3,
        llm_opts: [max_tokens: 256, api_key: "lm-studio"]
      ]
  end
end

defmodule Aikido.Slices.AiReactE2ETest.EchoAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "react_e2e_echo"

    slice :ai, Aikido.Slices.AiReact,
      options: [
        model: %{
          provider: :openai,
          id: "google/gemma-4-26b-a4b",
          base_url: "http://localhost:1234/v1"
        },
        tools: [:test_echo],
        max_iterations: 5,
        llm_opts: [max_tokens: 256, api_key: "lm-studio"]
      ]
  end
end

defmodule Aikido.Slices.AiReactE2ETest.AddAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "react_e2e_add"

    slice :ai, Aikido.Slices.AiReact,
      options: [
        model: %{
          provider: :openai,
          id: "google/gemma-4-26b-a4b",
          base_url: "http://localhost:1234/v1"
        },
        tools: [:test_add],
        max_iterations: 5,
        llm_opts: [max_tokens: 256, api_key: "lm-studio"]
      ]
  end
end

defmodule Aikido.Slices.AiReactE2ETest do
  @moduledoc """
  End-to-end tests for the `Aikido.Slices.AiReact` slice against a local LM
  Studio server.

  These exercise the real `ReqLLM.Generation.generate_text/3` path — no
  Mimic stubs — through the full slice composition pattern: a regular
  `Aikido.Agent` with `Aikido.Slices.AiReact` attached via `extensions:`, started
  under `Aikido.AgentServer`, queried via `Aikido.AI.ask_sync/3`. Requires a
  model running at the configured base URL.

  The api key lives in the slice's `llm_opts: [api_key: ...]` (per-slice
  config); per-call overrides are also possible via the `:llm_opts` opt
  on `Aikido.AI.ask/3`.

  Tagged `:e2e` and excluded from the default test run. To enable:

      mix test --include e2e

  The model identity (provider, id, base url) and api key are inlined as
  literals to keep the agent's `extensions:` value `Macro.quoted_literal?`-
  friendly. Adjust them to point at a different local model server if
  needed.
  """
  use AikidoTest.Case, async: false
  @moduletag :e2e
  @moduletag timeout: 120_000

  test("produces a final answer for a simple question without tools", ctx) do
    pid = start_server(ctx, Aikido.Slices.AiReactE2ETest.NoToolsAgent)
    assert {:ok, text} = Aikido.AI.ask_sync(pid, "What is 2 + 2?", timeout: 60000)
    assert is_binary(text)
    assert text =~ "4"
  end

  test("drives a tool-calling round trip when the model picks a tool", ctx) do
    pid = start_server(ctx, Aikido.Slices.AiReactE2ETest.EchoAgent)

    assert {:ok, text} =
             Aikido.AI.ask_sync(
               pid,
               "You have a tool named test_echo that echoes a message. " <>
                 "Call it once with the message 'hello-from-aikido', then reply 'done'.",
               timeout: 90000
             )

    assert is_binary(text)
    {:ok, ai} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.ai} end)
    tool_messages = ai.context |> ReqLLM.Context.to_list() |> Enum.filter(&(&1.role == :tool))
    assert tool_messages != [], "expected the model to call test_echo at least once"
    assert hd(tool_messages).name == "test_echo"
  end

  test("handles a numeric tool call without crashing", ctx) do
    pid = start_server(ctx, Aikido.Slices.AiReactE2ETest.AddAgent)

    assert {:ok, text} =
             Aikido.AI.ask_sync(
               pid,
               "You have a tool named test_add that adds two integers. " <>
                 "Use it to compute 4 + 7, then state the result.",
               timeout: 90000
             )

    assert is_binary(text)
    assert text =~ "11"
  end

  test("out-of-band subscription observes every intermediate signal", ctx) do
    pid = start_server(ctx, Aikido.Slices.AiReactE2ETest.AddAgent)

    {:ok, sub_ref} =
      Aikido.AgentServer.subscribe(pid, "ai.react.**", fn state ->
        ai = state.agent.state.ai

        if is_nil(ai.request_id) do
          :skip
        else
          {:ok, %{status: ai.status, iteration: ai.iteration}}
        end
      end)

    assert {:ok, request_id} =
             Aikido.AI.ask(
               pid,
               "You have a tool named test_add that adds two integers. " <>
                 "Use it to compute 4 + 7, then state the result."
             )

    assert is_binary(request_id)
    {max_iter, count} = drain_until_completed(sub_ref, 90000)

    assert max_iter >= 1,
           "expected the model to drive at least one tool turn (iteration >= 1); got #{max_iter}"

    assert count >= 2,
           "expected multiple intermediate signals; received #{count}"

    :ok = Aikido.AgentServer.unsubscribe(pid, sub_ref)
  end

  defp drain_until_completed(sub_ref, deadline_ms, acc \\ {0, 0})

  defp drain_until_completed(sub_ref, deadline_ms, {max_iter, count}) do
    receive do
      {:aikido_subscription, ^sub_ref, %{result: {:ok, %{status: :completed, iteration: iter}}}} ->
        {max(max_iter, iter), count + 1}

      {:aikido_subscription, ^sub_ref, %{result: {:ok, %{status: :failed} = projection}}} ->
        flunk("slice transitioned to :failed mid-run: #{inspect(projection)}")

      {:aikido_subscription, ^sub_ref, %{result: {:ok, %{status: :running, iteration: iter}}}} ->
        drain_until_completed(sub_ref, deadline_ms, {max(max_iter, iter), count + 1})
    after
      deadline_ms ->
        flunk(
          "no :completed dispatch within #{deadline_ms}ms; saw #{count} non-terminal dispatches"
        )
    end
  end
end
