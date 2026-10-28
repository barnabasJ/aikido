Mimic.copy(ReqLLM.Generation)
Mimic.copy(AshAi)

{:ok, _authority} = AikidoTest.DurableScopeAuthority.start_link()

Application.put_env(:aikido, :durable,
  scope_adapter: AikidoTest.DurableScopeAuthority,
  durable_options: [discovery_interval_ms: 100]
)

ExUnit.start()
