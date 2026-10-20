Mimic.copy(ReqLLM.Generation)
Mimic.copy(AshAi)

Application.put_env(:aikido, :durable, durable_options: [discovery_interval_ms: 100])

ExUnit.start()
