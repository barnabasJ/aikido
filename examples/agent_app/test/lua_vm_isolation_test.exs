defmodule AgentExamples.LuaVmIsolationTest do
  use ExUnit.Case, async: true

  test "hook and agent VMs expose independent application capabilities" do
    hook =
      Ash.create!(Aikido.AiReact.Hooks.Hook, %{
        name: "isolated hook",
        event: :before_model,
        lua_options: [otp_app: :agent_examples, labels: [:approvals]],
        script: """
        assert(approvals.review ~= nil)
        assert(analysis == nil and agents == nil)
        hook_only_global = true
        return nil
        """
      })

    assert {:ok, %{decision: :continue}} =
             Aikido.AiReact.Directives.ExecuteHook.evaluate_lua_hook(
               hook,
               %{},
               self(),
               "isolation"
             )

    assert {:ok, _} =
             AgentExamples.AI.LuaSurface
             |> Ash.ActionInput.for_action(:run_script, %{
               script: """
               assert(analysis.text_stats ~= nil and agents.members ~= nil)
               assert(approvals == nil and hook_only_global == nil)
               return true
               """
             })
             |> Ash.run_action()
  end

  test "approval authorization is enforced by native policies and the hook action surface" do
    input =
      Ash.ActionInput.for_action(AgentExamples.InteractiveAssistant.Approvals, :review, %{
        title: "Approval",
        choices: ["approve", "deny"]
      })

    assert Ash.can?(input, %{id: "owner"}, tenant: "playground")
    refute Ash.can?(input, nil, tenant: "playground")
    refute Ash.can?(input, %{}, tenant: "playground")
    refute Ash.can?(input, %{id: "owner"}, tenant: "another-tenant")

    hook =
      Ash.create!(Aikido.AiReact.Hooks.Hook, %{
        name: "denied approval",
        event: :before_model,
        lua_options: [otp_app: :agent_examples, labels: [:approvals]],
        script: """
        local result, err = approvals.review({input = {title = "Approval", choices = {"approve"}}})
        assert(result == nil and err ~= nil)
        return nil
        """
      })

    for scope <- [
          %{tenant: "playground"},
          %{actor: %{}, tenant: "playground"},
          %{actor: %{id: "owner"}, tenant: "another-tenant"}
        ] do
      signal = %Aikido.Signal{type: "test.approval", scope: scope}

      assert {:ok, %{decision: :continue}} =
               Aikido.AiReact.Directives.ExecuteHook.evaluate_lua_hook(
                 hook,
                 %{},
                 self(),
                 "denied",
                 signal
               )
    end
  end
end
