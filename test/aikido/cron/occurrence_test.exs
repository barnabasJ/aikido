defmodule AikidoTest.AgentServer.CronOccurrenceTest do
  use ExUnit.Case, async: true

  test "each generated occurrence gets its own envelope after registration" do
    template = %Aikido.Signal{id: nil, type: "test.tick", source: "/test", data: %{v: 1}}

    for spec <- [
          Aikido.Cron.RuntimeSpec.schedule("@yearly", "test.tick", nil, %{v: 1}),
          Aikido.Cron.RuntimeSpec.dynamic("@yearly", template),
          Aikido.Cron.RuntimeSpec.dynamic("@yearly", :tick)
        ] do
      runtime =
        %Aikido.AgentServer.State{
          id: "occurrences",
          agent_module: __MODULE__,
          agent: %{},
          aikido: nil
        }

      {:ok, job} = Aikido.Cron.Scheduler.start_job(runtime.id, :tick, spec)
      on_exit(fn -> Aikido.Cron.Scheduler.cancel(job) end)
      send(job, :tick)
      assert_receive {:"$gen_cast", {:signal, first}}, 1_000
      send(job, :tick)
      assert_receive {:"$gen_cast", {:signal, second}}, 1_000
      assert first.id != second.id
      assert is_binary(first.time)
      assert is_binary(second.time)
      assert first.type == second.type
      assert first.data == second.data
      assert :ok = Aikido.Cron.Scheduler.cancel(job)
    end
  end

  test "Cron retains an incomplete descriptor for later occurrences" do
    template = %Aikido.Signal{id: nil, type: "test.tick", source: "/test", data: %{v: 1}}
    input = Aikido.Signal.new!("test.register", %{})

    runtime =
      %Aikido.AgentServer.State{id: "template", agent_module: __MODULE__, agent: %{}, aikido: nil}

    directive = %Aikido.Cron.Directives.Register{
      cron: "@yearly",
      job_id: :tick,
      message: template
    }

    assert :ok = Aikido.Directive.exec(directive, input, runtime)

    assert_receive {:"$gen_cast",
                    {:signal, %{type: "aikido.agent.cron.registered", data: registered}}}

    job = registered.pid
    on_exit(fn -> Aikido.Cron.Scheduler.cancel(job) end)
    assert registered.runtime_spec.message.id == nil
    assert registered.runtime_spec.message.time == nil

    assert Aikido.Cron.RuntimeSpec.build_signal(
             registered.runtime_spec,
             "template",
             :tick
           ).data == %{v: 1}

    send(job, :tick)
    assert_receive {:"$gen_cast", {:signal, first}}, 1_000
    send(job, :tick)
    assert_receive {:"$gen_cast", {:signal, second}}, 1_000
    assert first.id != second.id
    assert :ok = Aikido.Cron.Scheduler.cancel(job)
  end

  test "an explicitly constructed envelope keeps its caller supplied identity" do
    signal = Aikido.Signal.new!("test.tick", %{}, time: "2020-01-01T00:00:00Z")
    spec = Aikido.Cron.RuntimeSpec.dynamic("@yearly", signal)
    assert Aikido.Cron.RuntimeSpec.build_signal(spec, "agent", :tick) == signal
  end
end
