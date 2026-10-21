defmodule Aikido.HooksVmTest.ReadScope do
  @moduledoc "Returns the caller scope observed by a configured hook action."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    {:ok, %{actor: context.actor.id, tenant: context.tenant, marker: input.context.marker}}
  end
end

defmodule Aikido.HooksVmTest.Actions do
  @moduledoc "Native Ash actions exposed selectively to hook VMs."
  use Ash.Resource, domain: Aikido.HooksVmTest.Domain

  actions do
    action :read_scope, :map do
      run Aikido.HooksVmTest.ReadScope
    end
  end
end

defmodule Aikido.HooksVmTest.EvalSurface do
  @moduledoc "An upstream AshLua scoped surface usable by hook configuration."
  use Ash.Resource, domain: Aikido.HooksVmTest.Domain, extensions: [AshLua.EvalActions]

  eval_actions do
    otp_app :aikido_hook_vm_test
    labels [:hook]
  end
end

defmodule Aikido.HooksVmTest.Domain do
  @moduledoc "Maps hook actions onto an application-owned Lua namespace."
  use Ash.Domain,
    otp_app: :aikido_hook_vm_test,
    validate_config_inclusion?: false,
    extensions: [AshLua.Domain]

  resources do
    resource Aikido.HooksVmTest.Actions
    resource Aikido.HooksVmTest.EvalSurface
  end

  lua do
    namespace "hooks" do
      action :read_scope, Aikido.HooksVmTest.Actions, :read_scope, labels: [:hook]
    end
  end
end

defmodule Aikido.HooksVmTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.fetch_env(:aikido_hook_vm_test, :ash_domains)
    Application.put_env(:aikido_hook_vm_test, :ash_domains, [Aikido.HooksVmTest.Domain])

    on_exit(fn ->
      case previous do
        {:ok, domains} -> Application.put_env(:aikido_hook_vm_test, :ash_domains, domains)
        :error -> Application.delete_env(:aikido_hook_vm_test, :ash_domains)
      end
    end)

    :ok
  end

  test "configured AshLua surfaces execute real actions with the current caller scope" do
    for options <- [
          [otp_app: :aikido_hook_vm_test],
          [otp_app: :aikido_hook_vm_test, labels: [:hook]],
          [
            otp_app: :aikido_hook_vm_test,
            action_entrypoints: [{Aikido.HooksVmTest.Actions, :read_scope}]
          ],
          [eval_resource: Aikido.HooksVmTest.EvalSurface]
        ] do
      hook =
        hook(
          """
          local result = assert(hooks.read_scope({}))
          return {context = result.actor .. ":" .. result.tenant .. ":" .. result.marker}
          """,
          options
        )

      for caller <- ["alice", "bob"] do
        signal = %Aikido.Signal{
          type: "test.hook",
          scope: %{actor: %{id: caller}, tenant: "org-" <> caller, context: %{marker: "native"}}
        }

        assert {:ok, %{context: context}} =
                 Aikido.AiReact.Directives.ExecuteHook.evaluate_lua_hook(
                   hook,
                   %{},
                   self(),
                   "run",
                   signal
                 )

        assert context == "#{caller}:org-#{caller}:native"
      end
    end
  end

  test "unconfigured and filtered hook VMs expose no application actions" do
    for options <- [
          [],
          [otp_app: :aikido_hook_vm_test, labels: [:unavailable]],
          [otp_app: :aikido_hook_vm_test, action_entrypoints: []]
        ] do
      assert {:ok, %{decision: :continue}} =
               Aikido.AiReact.Directives.ExecuteHook.evaluate_lua_hook(
                 hook("assert(hooks == nil); return nil", options),
                 %{},
                 self(),
                 "run"
               )
    end
  end

  test "each execution gets a fresh VM with no script globals retained" do
    hook = hook("assert(previous == nil); previous = true; return nil", [])

    for _ <- 1..2 do
      assert {:ok, %{decision: :continue}} =
               Aikido.AiReact.Directives.ExecuteHook.evaluate_lua_hook(hook, %{}, self(), "run")
    end
  end

  test "surface configuration round-trips through native Ash storage without runtime credentials" do
    options = [
      otp_app: :aikido_hook_vm_test,
      labels: [:hook],
      action_entrypoints: [{Aikido.HooksVmTest.Actions, :read_scope}]
    ]

    hook = hook("return nil", options ++ [actor: %{id: "secret"}, context: %{token: "secret"}])
    attribute = Ash.Resource.Info.attribute(Aikido.AiReact.Hooks.Hook, :lua_options)

    assert hook.lua_options == options

    assert {:ok, stored} =
             Ash.Type.dump_to_native(attribute.type, hook.lua_options, attribute.constraints)

    assert {:ok, json} = Jason.encode(stored)
    assert {:ok, decoded} = Jason.decode(json)
    assert {:ok, restored} = Ash.Type.cast_stored(attribute.type, decoded, attribute.constraints)
    assert restored == options
    refute json =~ "secret"
  end

  defp hook(script, options) do
    {:ok, hook} =
      Ash.Type.cast_input(Aikido.AiReact.Hooks.Hook, %{
        name: "native surface",
        event: :before_model,
        script: script,
        lua_options: options
      })

    hook
  end
end
