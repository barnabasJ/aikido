defmodule AikidoTest.AgentServer.CronOccurrenceTest do
  use ExUnit.Case, async: true

  test "each generated occurrence gets its own envelope after registration" do
    template = %Jido.Signal{id: nil, type: "test.tick", source: "/test", data: %{v: 1}}

    for spec <- [
          Aikido.AgentServer.CronRuntimeSpec.schedule("@yearly", "test.tick", nil, %{v: 1}),
          Aikido.AgentServer.CronRuntimeSpec.dynamic("@yearly", template),
          Aikido.AgentServer.CronRuntimeSpec.dynamic("@yearly", :tick)
        ] do
      runtime =
        %Aikido.AgentServer.State{
          id: "occurrences",
          agent_module: __MODULE__,
          agent: %{},
          aikido: nil
        }

      {:ok, job} = Aikido.AgentServer.start_runtime_cron_job(runtime, :tick, spec)
      on_exit(fn -> Aikido.Scheduler.cancel(job) end)
      send(job, :tick)
      assert_receive {:"$gen_cast", {:signal, first}}, 1_000
      send(job, :tick)
      assert_receive {:"$gen_cast", {:signal, second}}, 1_000
      assert first.id != second.id
      assert is_binary(first.time)
      assert is_binary(second.time)
      assert first.type == second.type
      assert first.data == second.data
      assert :ok = Aikido.Scheduler.cancel(job)
    end
  end

  test "Cron retains an incomplete descriptor for later occurrences" do
    template = %Jido.Signal{id: nil, type: "test.tick", source: "/test", data: %{v: 1}}
    input = Jido.Signal.new!("test.register", %{})

    runtime =
      %Aikido.AgentServer.State{id: "template", agent_module: __MODULE__, agent: %{}, aikido: nil}

    directive = %Aikido.Directives.Cron{cron: "@yearly", job_id: :tick, message: template}
    assert :ok = Aikido.Directive.exec(directive, input, runtime)

    assert_receive {:"$gen_cast",
                    {:signal, %{type: "aikido.agent.cron.registered", data: registered}}}

    job = registered.pid
    on_exit(fn -> Aikido.Scheduler.cancel(job) end)
    assert registered.runtime_spec.message.id == nil
    assert registered.runtime_spec.message.time == nil

    assert Aikido.AgentServer.CronRuntimeSpec.build_signal(
             registered.runtime_spec,
             "template",
             :tick
           ).data == %{v: 1}

    send(job, :tick)
    assert_receive {:"$gen_cast", {:signal, first}}, 1_000
    send(job, :tick)
    assert_receive {:"$gen_cast", {:signal, second}}, 1_000
    assert first.id != second.id
    assert :ok = Aikido.Scheduler.cancel(job)
  end

  test "an explicitly constructed envelope keeps its caller supplied identity" do
    signal = Jido.Signal.new!("test.tick", %{}, time: "2020-01-01T00:00:00Z")
    spec = Aikido.AgentServer.CronRuntimeSpec.dynamic("@yearly", signal)
    assert Aikido.AgentServer.CronRuntimeSpec.build_signal(spec, "agent", :tick) == signal
  end
end
