defmodule AikidoTest.Case do
  @moduledoc """
  Test case module that provides isolated Aikido instances for testing.

  ## Usage

      defmodule MyTest do
        use AikidoTest.Case, async: true
        
        test "my test", %{aikido: aikido} do
          {:ok, pid} = Aikido.start_agent(aikido, MyAgent)
          # ...
        end
      end

  Each test gets a unique Aikido instance that is automatically started before
  the test and stopped after it completes. This ensures complete test isolation.

  ## Context

  The following keys are available in the test context:

  - `:aikido` - The name of the Aikido instance (atom)
  - `:aikido_pid` - The PID of the Aikido supervisor

  ## Helper Functions

  The module also provides helper functions:

  - `start_test_agent/3` - Starts an agent under the test's Aikido instance
  - `unique_id/1` - Generates a unique ID with optional prefix
  - `signal/3` - Creates a test signal with sensible defaults
  - `start_server/3` - Starts an agent server with automatic cleanup
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import AikidoTest.Case
      import AikidoTest.AgentWait

      @doc """
      Starts an agent under this test's Aikido instance.
      """
      def start_test_agent(context, agent, opts \\ []) do
        Aikido.start_agent(context.aikido, agent, opts)
      end
    end
  end

  @doc """
  Generates a unique ID with an optional prefix.

  ## Examples

      unique_id()        # "test-12345"
      unique_id("agent") # "agent-12346"
  """
  def unique_id(prefix \\ "test") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Creates a test signal with sensible defaults.

  ## Examples

      signal("increment")
      signal("record", %{message: "hello"})
      signal("test", %{}, source: "/custom")
  """
  def signal(type, data \\ %{}, opts \\ []) do
    source = Keyword.get(opts, :source, "/test")
    Jido.Signal.new!(type, data, source: source)
  end

  @doc """
  Starts an agent server with automatic cleanup on test exit.

  ## Options

  Runtime integration tests use the internal `Aikido.start_agent/3` path, with defaults:

    * `:aikido` - Uses the test context's aikido instance
    * `:id` - Generates a unique ID if not provided

  ## Examples

      pid = start_server(context, MyAgent)
      pid = start_server(context, MyAgent, id: "custom-id")
  """
  def start_server(context, agent, opts \\ []) do
    {instance, opts} = Keyword.pop(opts, :aikido, context.aikido)
    opts = Keyword.put_new(opts, :id, unique_id())
    {:ok, pid} = Aikido.start_agent(instance, agent, opts)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid) do
        try do
          Aikido.stop_agent(instance, pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    pid
  end

  setup context do
    test_id = System.unique_integer([:positive])
    aikido_name = :"aikido_test_#{test_id}"

    aikido_pid = start_supervised!({Aikido, name: aikido_name, durable: durable_options()})

    {:ok, Map.merge(context, %{aikido: aikido_name, aikido_pid: aikido_pid})}
  end

  @doc "An isolated native DurableServer backend for one test."
  def durable_options do
    directory = Path.join(System.tmp_dir!(), "aikido-test-#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)

    [
      data_dir: directory,
      durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]
    ]
  end
end
