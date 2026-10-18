# Suppress the Discovery module's info log during startup
# The capture_log: true option captures test logs, but Discovery logs happen
# before tests run. We handle this by temporarily setting compile_time_purge_level.
# However, since that's a compile-time option, we accept the Discovery log.

Mimic.copy(ReqLLM.Generation)

# Most runtime tests exercise the lightweight AgentServer directly. Durability
# integration tests explicitly enable a disk-backed pool with an isolated path.
Application.put_env(:aikido, :durable, false)

ExUnit.start()
ExUnit.configure(exclude: [:flaky, :e2e])
