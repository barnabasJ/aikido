defmodule AgentExamples.ProviderLuaTracingTest do
  use ExUnit.Case, async: false
  require Ash.Tracer
  alias AgentExamples.{Agents, AI}

  test "Lua script failures reach the model and count toward the configured tool error limit" do
    observer = self()
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      messages = Jason.decode!(body)["messages"]
      results = Enum.filter(messages, &(&1["role"] == "tool"))
      send(observer, {:model_tool_errors, results})

      Req.Test.json(conn, %{
        id: "lua-error-response",
        model: "glm-5.3-flash",
        choices: [
          %{
            index: 0,
            message: %{
              role: "assistant",
              content: "",
              tool_calls: [
                %{
                  id: "invalid-lua-#{length(results)}",
                  type: "function",
                  function: %{
                    name: "run_lua",
                    arguments: Jason.encode!(%{input: %{script: "local = invalid syntax"}})
                  }
                }
              ]
            },
            finish_reason: "tool_calls"
          }
        ],
        usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      })
    end)

    agent =
      Agents.assistant_start!(%{
        model: %{provider: :zai_coder, id: "glm-5.3-flash"},
        client: ReqLLM.Generation,
        tools: AI.Tools.for_lua(),
        tool_options: [otp_app: :agent_examples],
        options: %{streaming: false, max_consecutive_tool_errors: 2},
        llm_opts: [api_key: "test-only", req_http_options: [plug: {Req.Test, __MODULE__}]]
      })

    on_exit(fn -> Agents.assistant_stop(agent) end)

    assert {:error, {:tool_error_limit, 2}} = AI.ask(agent, "Exercise Lua failure recovery")
    assert_receive {:model_tool_errors, []}
    assert_receive {:model_tool_errors, [first_error]}

    assert %{"code" => "lua_script_failed", "recovery" => recovery} =
             Jason.decode!(first_error["content"])

    assert recovery =~ "correct the script"
    refute first_error["content"] =~ "unexpected error occurred"
    state = Agents.assistant_inspect!(agent).ai
    assert state.status == :failed
    assert state.iteration == 2
    assert state.tool_error_streak == 2
    results = Enum.filter(state.context.messages, &(&1.role == :tool))
    assert length(results) == 2
    assert Enum.all?(results, & &1.metadata.aikido_tool_error?)
  end

  test "a provider token limit fails with recovery guidance instead of accepting a partial answer" do
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        id: "truncated-response",
        model: "glm-5.3-flash",
        choices: [
          %{
            index: 0,
            message: %{role: "assistant", content: "Unfinished answer..."},
            finish_reason: "length"
          }
        ],
        usage: %{prompt_tokens: 10, completion_tokens: 32, total_tokens: 42}
      })
    end)

    agent =
      Agents.assistant_start!(%{
        model: %{provider: :zai_coder, id: "glm-5.3-flash"},
        client: ReqLLM.Generation,
        tools: [],
        options: %{streaming: false},
        llm_opts: [
          max_tokens: 32,
          api_key: "test-only",
          req_http_options: [plug: {Req.Test, __MODULE__}]
        ]
      })

    on_exit(fn -> Agents.assistant_stop(agent) end)

    assert {:error, %Aikido.AiReact.Errors.OutputTruncated{max_tokens: 32} = error} =
             AI.ask(agent, "Answer a long question")

    assert AshAi.ToToolError.to_tool_error(error) =~ "Increase max_tokens"
    assert AshLua.Error.to_error(error).code == "model_output_truncated"
    current = Agents.assistant_inspect!(agent.id)
    assert current.ai.status == :failed
    assert current.ai.result == nil
    assert current.ai.usage.output_tokens == 32
  end

  for style <- [:options, :scope] do
    test "a native HTTP model turn and Lua-dispatched action retain the originating #{style} Ash trace" do
      observer = self()
      Req.Test.set_req_test_to_shared()

      Req.Test.stub(__MODULE__, fn conn ->
        send(observer, {:provider_attempt_trace, Ash.Tracer.Simple.get_span_context()})
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        messages = Jason.decode!(body)["messages"]
        tool_result = Enum.find(messages, &(&1["role"] == "tool"))

        message =
          if tool_result do
            send(observer, {:lua_tool_result, tool_result["content"]})
            %{role: "assistant", content: "Two words verified through Lua."}
          else
            %{
              role: "assistant",
              content: "",
              tool_calls: [
                %{
                  id: "lua-analysis",
                  type: "function",
                  function: %{
                    name: "run_lua",
                    arguments:
                      Jason.encode!(%{
                        input: %{
                          script:
                            "return assert(analysis.text_stats({input = {text = 'hello world'}}))"
                        }
                      })
                  }
                }
              ]
            }
          end

        Req.Test.json(conn, %{
          id: "tracing-response",
          object: "chat.completion",
          model: "gpt-4o",
          choices: [
            %{
              index: 0,
              message: message,
              finish_reason: if(tool_result, do: "stop", else: "tool_calls")
            }
          ],
          usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
        })
      end)

      agent =
        Agents.assistant_start!(%{
          model: %{provider: :zai_coder, id: "glm-5.3-flash"},
          client: ReqLLM.Generation,
          tools: AI.Tools.for_lua(),
          tool_options: [otp_app: :agent_examples],
          options: %{streaming: false},
          llm_opts: [api_key: "test-only", req_http_options: [plug: {Req.Test, __MODULE__}]]
        })

      on_exit(fn -> Agents.assistant_stop(agent) end)

      ash =
        if unquote(style) == :scope,
          do: [scope: %{tracer: Ash.Tracer.Simple}],
          else: [tracer: Ash.Tracer.Simple]

      Ash.Tracer.span :custom, "provider-lua-scenario", Ash.Tracer.Simple do
        assert {:ok, "Two words verified through Lua."} =
                 AI.ask(agent, "Count hello world", ash: ash)
      end

      assert_receive {:provider_attempt_trace, %{pid: ^observer, parent_id: parent}}, 5_000
      assert is_binary(parent)
      assert_receive {:lua_tool_result, result}, 5_000
      assert Jason.decode!(result)["error"] == nil
      assert result =~ ~s("words":2)
      refute result =~ "unknown_error"

      spans = drain_spans([])
      assert Enum.any?(spans, &(&1.type == {:custom, :aikido_model_call}))
      assert Enum.any?(spans, &(&1.type == {:custom, :aikido_attempt}))

      eval =
        Enum.find(
          spans,
          &(&1.type == :action and &1.metadata[:resource] == AgentExamples.AI.LuaSurface and
              &1.metadata[:action] == :eval)
        )

      assert eval

      stats =
        Enum.find(
          spans,
          &(&1.type == :action and &1.metadata[:resource] == AgentExamples.AI.Tools and
              &1.metadata[:action] == :text_stats)
        )

      assert stats
      assert stats.parent_id == eval.id
      root = Enum.find(spans, &(&1.name == "provider-lua-scenario"))
      assert reaches_root?(spans, eval, root.id)
      assert reaches_root?(spans, Enum.find(spans, &(&1.id == parent)), root.id)
    end
  end

  defp drain_spans(spans) do
    receive do
      {:span, span} -> drain_spans([span | spans])
    after
      0 -> spans
    end
  end

  defp reaches_root?(_, %{id: id}, id), do: true
  defp reaches_root?(_, nil, _), do: false

  defp reaches_root?(spans, span, root),
    do: reaches_root?(spans, Enum.find(spans, &(&1.id == span.parent_id)), root)
end
