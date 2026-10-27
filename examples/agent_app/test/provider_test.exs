defmodule AgentExamples.ProviderTest do
  use ExUnit.Case, async: false
  alias AgentExamples.{AI, Playground}

  test "keys are isolated between browser sessions and blank updates keep the existing key" do
    owner = Ash.UUIDv7.generate()

    params = %{
      "mode" => "live",
      "provider" => "zai",
      "model" => "glm-5.3",
      "api_key" => "local-test-key"
    }

    assert {:ok, _} = Playground.configure_provider(owner, params)
    assert {:ok, _} = Playground.configure_provider(owner, Map.put(params, "api_key", ""))
    assert {:ok, "local-test-key"} = Playground.provider_key(owner, :zai)
    assert {:error, _} = Playground.provider_key(Ash.UUIDv7.generate(), :zai)
    refute inspect(Playground.provider_settings(owner)) =~ "local-test-key"
    refute inspect(:sys.get_status(Playground), limit: :infinity) =~ "local-test-key"
  end

  test "live examples and their workers share larger bounded request budgets" do
    owner = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Playground.configure_provider(owner, %{
               "mode" => "live",
               "provider" => "zai_coder",
               "model" => "glm-5.3-flash",
               "api_key" => "budget-test-key"
             })

    on_exit(fn -> Playground.stop(owner, "research-team") end)
    assert {:ok, run} = Playground.start(owner, "research-team", %{"lua" => "true"})

    assert {:ok, _} =
             AgentExamples.ResearchTeam
             |> Ash.ActionInput.for_action(:add_member, %{
               agent: run.record,
               member: "budget-squad",
               template: :squad
             })
             |> Ash.run_action()

    assert {:ok, {options, llm_opts, workers}} =
             Aikido.AgentServer.state(
               run.record.pid,
               &{:ok,
                {&1.agent.state.ai.options, &1.agent.state.ai.llm_opts,
                 &1.agent.state.team.members}}
             )

    assert options.model_timeout_ms == 600_000
    assert llm_opts[:max_tokens] == 16_384
    assert llm_opts[:receive_timeout] == 600_000
    assert options.tool_timeout_ms == 3_600_000
    assert options.model_max_retries == 4
    assert options.retry_backoff_ms == 10_000

    assert map_size(workers) == 1

    for {_name, pid} <- workers do
      assert {:ok, {^options, ^llm_opts, members}} =
               Aikido.AgentServer.state(
                 pid,
                 &{:ok,
                  {&1.agent.state.ai.options, &1.agent.state.ai.llm_opts,
                   &1.agent.state.team.members}}
               )

      assert members == %{}

      assert {:ok, _} =
               AgentExamples.ResearchSquad
               |> Ash.ActionInput.for_action(:add_member, %{
                 agent: pid,
                 member: "budget-researcher",
                 template: :researcher
               })
               |> Ash.run_action()

      assert {:ok, researcher} =
               Aikido.AgentServer.state(
                 pid,
                 &{:ok, Map.fetch!(&1.agent.state.team.members, "budget-researcher")}
               )

      assert {:ok, {^options, ^llm_opts}} =
               Aikido.AgentServer.state(
                 researcher,
                 &{:ok, {&1.agent.state.ai.options, &1.agent.state.ai.llm_opts}}
               )
    end
  end

  test "the live client uses the native z.ai request with the session key, without a network call" do
    owner = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Playground.configure_provider(owner, %{
               "mode" => "live",
               "provider" => "zai",
               "model" => "glm-5.3",
               "api_key" => "native-request-test"
             })

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer native-request-test"]
      assert conn.host == "api.z.ai"

      Req.Test.json(conn, %{
        id: "test",
        model: "glm-5.3",
        choices: [
          %{
            index: 0,
            message: %{role: "assistant", content: "Real provider path"},
            finish_reason: "stop"
          }
        ],
        usage: %{prompt_tokens: 1, completion_tokens: 2, total_tokens: 3}
      })
    end)

    assert {:ok, response} =
             AI.LiveClient.generate_text(
               %{credential_owner: owner, provider: :zai, id: "glm-5.3"},
               [ReqLLM.Context.user("hello")],
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert ReqLLM.Response.text(response) == "Real provider path"
  end

  test "live provider errors retain HTTP status and recovery without private response details" do
    owner = Ash.UUIDv7.generate()
    key = "redaction-test-key"

    assert {:ok, _} =
             Playground.configure_provider(owner, %{
               "mode" => "live",
               "provider" => "zai",
               "model" => "glm-5.3",
               "api_key" => key
             })

    for status <- [401, 429, 503] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{error: %{message: "Rejected #{key}"}})
      end)

      assert {:error, %Aikido.AiReact.Errors.ProviderRequestFailed{status: ^status} = error} =
               AI.LiveClient.generate_text(
                 %{credential_owner: owner, provider: :zai, id: "glm-5.3"},
                 [ReqLLM.Context.user("hello")],
                 req_http_options: [plug: {Req.Test, __MODULE__}, retry: false]
               )

      assert Exception.message(error) =~ "HTTP #{status}"
      assert error |> AshAi.ToToolError.to_tool_error() |> String.downcase() =~ "retry"
      refute inspect(error) =~ key
      refute Exception.message(error) =~ "Rejected"
    end
  end

  test "a missing live credential explains how to configure it" do
    assert {:error, message} =
             AI.LiveClient.generate_text(
               %{credential_owner: Ash.UUIDv7.generate(), provider: :zai, id: "glm-5.3"},
               [ReqLLM.Context.user("hello")],
               []
             )

    assert message =~ "Save the provider credential"
    assert message =~ "restart the example"
  end

  test "coding-plan providers send requests to the coding endpoint" do
    for provider <- [:zai_coder, :zai_coding_plan] do
      owner = Ash.UUIDv7.generate()

      assert {:ok, _} =
               Playground.configure_provider(owner, %{
                 "mode" => "live",
                 "provider" => to_string(provider),
                 "model" => "glm-5.3-flash",
                 "api_key" => "endpoint-test"
               })

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/api/coding/paas/v4/chat/completions"

        Req.Test.json(conn, %{
          id: "test",
          model: "glm-5.3-flash",
          choices: [
            %{
              index: 0,
              message: %{role: "assistant", content: "coding endpoint"},
              finish_reason: "stop"
            }
          ]
        })
      end)

      assert {:ok, _} =
               AI.LiveClient.generate_text(
                 %{credential_owner: owner, provider: provider, id: "glm-5.3-flash"},
                 [ReqLLM.Context.user("hello")],
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  test "switching z.ai endpoints preserves the submitted key instead of selecting an environment key" do
    owner = Ash.UUIDv7.generate()

    params = %{
      "mode" => "live",
      "provider" => "zai",
      "model" => "glm-5.3-flash",
      "api_key" => "submitted-plan-key"
    }

    assert {:ok, _} = Playground.configure_provider(owner, params)

    for provider <- ["zai_coder", "zai_coding_plan", "zai"] do
      assert {:ok, _} =
               Playground.configure_provider(owner, %{
                 params
                 | "provider" => provider,
                   "api_key" => ""
               })

      assert {:ok, "submitted-plan-key"} = Playground.provider_key(owner, provider)
    end
  end
end
