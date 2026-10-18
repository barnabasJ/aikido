defmodule Aikido.Sensors.Heartbeat do
  @moduledoc """
  A sensor that emits heartbeat signals at configurable intervals.

  ## Configuration

  - `interval` - Interval between heartbeats in milliseconds (default: 5000)
  - `message` - Message to include in heartbeat signal (default: "heartbeat")

  ## Example

      # Start via SensorServer
      {:ok, pid} = Aikido.Sensor.Runtime.start_link(
        sensor: Aikido.Sensors.Heartbeat,
        config: %{interval: 1000, message: "alive"}
      )
  """
  use Aikido.Sensor

  sensor do
    name "heartbeat"
    description "Emits heartbeat signals at configurable intervals"

    schema do
      attribute :interval, :integer,
        allow_nil?: false,
        default: 5000,
        description: "Interval between heartbeats in milliseconds"

      attribute :message, :string,
        allow_nil?: false,
        default: "heartbeat",
        description: "Message to include in heartbeat signal",
        constraints: [trim?: false, allow_empty?: true]
    end
  end

  @impl Aikido.Sensor
  def init(config, context) do
    state = %{
      target: context[:agent_ref],
      interval: config.interval,
      message: config.message
    }

    {:ok, state, schedule: config.interval}
  end

  @impl Aikido.Sensor
  def handle_event(:tick, state) do
    now = DateTime.utc_now()

    signal =
      Jido.Signal.new!(%{
        source: "/sensor/heartbeat",
        type: "aikido.sensor.heartbeat",
        data: %{
          message: state.message,
          timestamp: now
        }
      })

    {:ok, state, emit: signal, schedule: state.interval}
  end
end
