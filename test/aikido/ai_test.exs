defmodule Aikido.AITest.MathAgent do
  @moduledoc false
  use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

  agent do
    name "math"
  end

  slices do
    slice :ai, Aikido.Slices.AiReact
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [:test_add]
    system_prompt "You are precise."
    max_iterations 4
    max_tokens 256
    temperature 0.0
  end
end

defmodule Aikido.AITest.FailingAgent do
  @moduledoc false
  use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

  agent do
    name "failing"
  end

  slices do
    slice :ai, Aikido.Slices.AiReact
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [:test_fails]
    system_prompt "x"
    max_iterations 4
  end
end

defmodule Aikido.AITest.TightAgent do
  @moduledoc false
  use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

  agent do
    name "tight"
  end

  slices do
    slice :ai, Aikido.Slices.AiReact
  end

  react do
    model "anthropic:claude-haiku-4-5-20251001"
    tools [:test_add]
    system_prompt "x"
    max_iterations 1
  end
end

defmodule Aikido.AITest.NoModelAgent do
  @moduledoc false
  use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

  agent do
    name "no_model"
  end

  slices do
    slice :ai, Aikido.Slices.AiReact
  end

  react do
    tools [:test_add]
    max_iterations 2
  end
end

defmodule Aikido.AITest do
  use AikidoTest.Case, async: false
  use Mimic
  import Aikido.AI.Test.ResponseFixtures

  setup :set_mimic_global
  setup :verify_on_exit!

  describe("ask_sync/3 happy path") do
    test("slice config flows through to ReqLLM and the final answer is returned", ctx) do
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn model, messages, opts ->
        send(test_pid, {:llm, model, messages, opts})
        {:ok, final_answer_response("19")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      assert {:ok, "19"} = Aikido.AI.ask_sync(pid, "What is 5 + 7 * 2?", timeout: 1000)
      assert_receive {:llm, model, messages, opts}, 1000
      assert model == "anthropic:claude-haiku-4-5-20251001"
      assert opts[:max_tokens] == 256
      assert opts[:temperature] == 0.0
      [system, user] = messages
      assert system.role == :system
      assert system.content |> hd() |> Map.get(:text) == "You are precise."
      assert user.role == :user
    end
  end

  describe("ask/3 fire-and-forget") do
    test("returns {:ok, request_id} once the run is launched", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      assert {:ok, request_id} = Aikido.AI.ask(pid, "What is 5 + 7 * 2?")
      assert is_binary(request_id)
      assert String.starts_with?(request_id, "req_")

      assert :completed ==
               await_state_value(
                 pid,
                 fn state ->
                   if state.agent.state.ai.status == :completed do
                     :completed
                   end
                 end,
                 pattern: "ai.react.**",
                 timeout: 1000
               )
    end

    test("caller can subscribe out-of-band and observe every intermediate signal", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"input" => %{"a" => 1, "b" => 2}}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("3")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)

      {:ok, sub_ref} =
        Aikido.AgentServer.subscribe(pid, "ai.react.**", fn state ->
          ai = state.agent.state.ai

          if is_nil(ai.request_id) do
            :skip
          else
            {:ok, %{status: ai.status, iteration: ai.iteration}}
          end
        end)

      assert {:ok, request_id} = Aikido.AI.ask(pid, "Add 1 and 2")
      assert is_binary(request_id)
      assert_receive {:aikido_subscription, ^sub_ref, %{result: {:ok, %{status: :running}}}}, 1000

      assert_receive {:aikido_subscription, ^sub_ref,
                      %{result: {:ok, %{status: :completed, iteration: 2}}}},
                     1000

      :ok = Aikido.AgentServer.unsubscribe(pid, sub_ref)
    end
  end

  describe("tool-using runs") do
    test("tool turn → tool exec → final answer turn", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert Enum.map(messages, & &1.role) == [:system, :user]
        {:ok, tool_call_response([{"test_add", %{"input" => %{"a" => 1, "b" => 2}}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        assert Enum.map(messages, & &1.role) == [:system, :user, :assistant, :tool]
        {:ok, final_answer_response("3")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      assert {:ok, "3"} = Aikido.AI.ask_sync(pid, "Add 1 and 2", timeout: 1000)
      ai = read_ai(pid)
      assert ai.status == :completed
      assert ai.iteration == 2
      assert ai.pending_tool_calls == []
      assert ai.tool_results_received == []
    end

    test("appends a cycle warning when consecutive tool batches are identical", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"input" => %{"a" => 1, "b" => 1}}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"input" => %{"a" => 1, "b" => 1}}}])}
      end)

      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        send(test_pid, {:third_call_messages, messages})
        {:ok, final_answer_response("done")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      assert {:ok, "done"} = Aikido.AI.ask_sync(pid, "loop", timeout: 1000)
      assert_receive {:third_call_messages, messages}, 1000

      texts =
        for msg <- messages,
            msg.role == :user,
            entry <- msg.content,
            text = Map.get(entry, :text) do
          text
        end

      assert Enum.any?(texts, &(&1 == Aikido.Slices.AiReact.cycle_warning()))
    end

    test("tool errors are returned as JSON in tool.completed (not as :failed)", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_fails", %{"input" => %{"reason" => "boom"}}}])}
      end)

      expect(ReqLLM.Generation, :generate_text, fn _model, messages, _opts ->
        tool_msg = Enum.find(messages, &(&1.role == :tool))
        assert tool_msg
        {:ok, final_answer_response("recovered")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.FailingAgent)
      assert {:ok, "recovered"} = Aikido.AI.ask_sync(pid, "use a broken tool", timeout: 1000)
    end
  end

  describe("max iterations") do
    test("settles :completed without a result when the cap is hit", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, tool_call_response([{"test_add", %{"input" => %{"a" => 1, "b" => 2}}}])}
      end)

      pid = start_test_server(ctx, Aikido.AITest.TightAgent)
      assert {:ok, nil} = Aikido.AI.ask_sync(pid, "loop", timeout: 1000)
      ai = read_ai(pid)
      assert ai.status == :completed
      assert ai.result == nil
      assert ai.iteration == 1
    end
  end

  describe("failure paths") do
    test("settles slice to :failed when ReqLLM returns an error", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:error, :rate_limited}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      assert {:error, :rate_limited} = Aikido.AI.ask_sync(pid, "boom", timeout: 1000)
      ai = read_ai(pid)
      assert ai.status == :failed
      assert ai.error == :rate_limited
    end

    test("second ask while running returns the action's :busy chain error", ctx) do
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        send(test_pid, {:running, self()})

        receive do
          :release -> :ok
        after
          5000 -> :ok
        end

        {:ok, final_answer_response("done")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      task = Task.async(fn -> Aikido.AI.ask_sync(pid, "first", timeout: 5000) end)
      assert_receive {:running, llm_pid}, 1000
      assert {:error, %Ash.Error.Unknown{} = error} = Aikido.AI.ask(pid, "second")
      assert Exception.message(error) =~ "busy"
      send(llm_pid, :release)
      assert {:ok, "done"} = Task.await(task, 1000)

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("third")}
      end)

      assert {:ok, "third"} = Aikido.AI.ask_sync(pid, "third", timeout: 1000)
    end

    test("ask_sync/3 returns {:error, :timeout} when no terminal signal arrives", ctx) do
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        send(test_pid, {:running, self()})

        receive do
          :release -> :ok
        after
          5000 -> :ok
        end

        {:ok, final_answer_response("late")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      task = Task.async(fn -> Aikido.AI.ask_sync(pid, "stall", timeout: 50) end)
      assert_receive {:running, llm_pid}, 1000
      assert {:error, :timeout} = Task.await(task, 1000)
      send(llm_pid, :release)
    end

    test("stale tool.completed signals are ignored", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      assert {:ok, "ok"} = Aikido.AI.ask_sync(pid, "ok", timeout: 1000)
      ai_before = read_ai(pid)

      stale =
        Jido.Signal.new!("ai.react.tool.completed", %{
          tool_call_id: "stale",
          name: "test_add",
          content: "{}",
          request_id: "different_request_id"
        })

      :ok = Aikido.AgentServer.cast(pid, stale)
      {:ok, :ok} = Aikido.AgentServer.state(pid, fn _ -> {:ok, :ok} end)
      assert read_ai(pid) == ai_before
    end

    test(
      "ask returns :no_model chain error when neither slice config nor opts supply a model",
      ctx
    ) do
      pid = start_test_server(ctx, Aikido.AITest.NoModelAgent)
      assert {:error, %Ash.Error.Unknown{}} = Aikido.AI.ask(pid, "anything")
    end
  end

  describe("per-call overrides") do
    test(":model and :system_prompt override the slice defaults", ctx) do
      override_model = "anthropic:claude-sonnet-4-6"
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn model, messages, _opts ->
        send(test_pid, {:called_with, model, messages})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)

      assert {:ok, "ok"} =
               Aikido.AI.ask_sync(pid, "anything",
                 model: override_model,
                 system_prompt: "Override prompt.",
                 timeout: 1000
               )

      assert_receive {:called_with, ^override_model, messages}, 1000
      [system | _] = messages
      assert system.role == :system
      assert system.content |> hd() |> Map.get(:text) == "Override prompt."
    end

    test(":model from per-call opts is enough when slice has no model", ctx) do
      expect(ReqLLM.Generation, :generate_text, fn model, _messages, _opts ->
        assert model == "openai:gpt-5"
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.NoModelAgent)

      assert {:ok, "ok"} =
               Aikido.AI.ask_sync(pid, "anything", model: "openai:gpt-5", timeout: 1000)
    end

    test(":tools override replaces slice defaults", ctx) do
      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, opts ->
        tools = Keyword.fetch!(opts, :tools)
        send(test_pid, {:tools, tools})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.MathAgent)
      assert {:ok, _} = Aikido.AI.ask_sync(pid, "anything", tools: [], timeout: 1000)
      assert_receive {:tools, []}, 1000
    end

    test(":api_key in slice config llm_opts is propagated to ReqLLM", ctx) do
      defmodule Elixir.Aikido.AITest.SliceKeyAgent do
        @moduledoc false
        use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

        agent do
          name "slice_key"
        end

        slices do
          slice :ai, Aikido.Slices.AiReact
        end

        react do
          model "anthropic:claude-haiku-4-5-20251001"
          tools []
          llm_opts api_key: "key-from-slice"
        end
      end

      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, opts ->
        send(test_pid, {:api_key, Keyword.get(opts, :api_key)})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.SliceKeyAgent)
      assert {:ok, "ok"} = Aikido.AI.ask_sync(pid, "anything", timeout: 1000)
      assert_receive {:api_key, "key-from-slice"}, 1000
    end

    test(":api_key per-call llm_opts overrides the slice default", ctx) do
      defmodule Elixir.Aikido.AITest.SliceKeyOverrideAgent do
        @moduledoc false
        use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

        agent do
          name "slice_key_override"
        end

        slices do
          slice :ai, Aikido.Slices.AiReact
        end

        react do
          model "anthropic:claude-haiku-4-5-20251001"
          tools []
          llm_opts api_key: "slice-default"
        end
      end

      test_pid = self()

      expect(ReqLLM.Generation, :generate_text, fn _model, _messages, opts ->
        send(test_pid, {:api_key, Keyword.get(opts, :api_key)})
        {:ok, final_answer_response("ok")}
      end)

      pid = start_test_server(ctx, Aikido.AITest.SliceKeyOverrideAgent)

      assert {:ok, "ok"} =
               Aikido.AI.ask_sync(pid, "anything",
                 llm_opts: [api_key: "per-call-key"],
                 timeout: 1000
               )

      assert_receive {:api_key, "per-call-key"}, 1000
    end
  end

  defp read_ai(pid) do
    {:ok, ai} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.ai} end)
    ai
  end

  defp start_test_server(ctx, agent_module) do
    start_server(ctx, agent_module)
  end
end
