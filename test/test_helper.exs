Mimic.copy(ReqLLM.Generation)

Application.put_env(:aikido, :durable, durable_options: [discovery_interval_ms: 100])

ExUnit.start()
ExUnit.configure(exclude: [:flaky, :e2e])
