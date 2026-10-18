defmodule Aikido.Dsl.SensorTest.MinimalSensor do
  @moduledoc false
  use Aikido.Sensor

  sensor do
    name "minimal_sensor"
  end

  @impl Aikido.Sensor
  def init(_config, _ctx) do
    {:ok, %{}}
  end

  @impl Aikido.Sensor
  def handle_event(_event, state) do
    {:ok, state}
  end
end

defmodule Aikido.Dsl.SensorTest.FullSensor do
  @moduledoc false
  use Aikido.Sensor

  sensor do
    name "full_sensor"
    description "Full sensor with every accessor populated."
    category "test"
    tags ["a", "b"]
    vsn "1.0.0"

    schema do
      attribute :interval, :integer, allow_nil?: false, default: 1000
    end
  end

  @impl Aikido.Sensor
  def init(_config, _ctx) do
    {:ok, %{}}
  end

  @impl Aikido.Sensor
  def handle_event(_event, state) do
    {:ok, state}
  end
end

defmodule Aikido.Dsl.SensorTest.TerminateSensor do
  @moduledoc false
  use Aikido.Sensor

  sensor do
    name "terminate_sensor"
  end

  @impl Aikido.Sensor
  def init(_config, _ctx) do
    {:ok, %{}}
  end

  @impl Aikido.Sensor
  def handle_event(_event, state) do
    {:ok, state}
  end
end

defmodule Aikido.Dsl.SensorTest do
  use ExUnit.Case, async: true

  describe("sectioned DSL accessor parity") do
    nil
    nil

    test "name/1 returns the configured name" do
      assert Map.get(
               Aikido.Dsl.Sensor.Info.sensor_options(Aikido.Dsl.SensorTest.FullSensor),
               :name
             ) == "full_sensor"

      assert Map.get(
               Aikido.Dsl.Sensor.Info.sensor_options(Aikido.Dsl.SensorTest.MinimalSensor),
               :name
             ) == "minimal_sensor"
    end

    test "description/1, category/1, tags/1, vsn/1 round-trip" do
      assert Map.get(
               Aikido.Dsl.Sensor.Info.sensor_options(Aikido.Dsl.SensorTest.FullSensor),
               :description
             ) == "Full sensor with every accessor populated."

      assert Map.get(
               Aikido.Dsl.Sensor.Info.sensor_options(Aikido.Dsl.SensorTest.FullSensor),
               :category
             ) == "test"

      assert Map.get(
               Aikido.Dsl.Sensor.Info.sensor_options(Aikido.Dsl.SensorTest.FullSensor),
               :tags
             ) == ["a", "b"]

      assert Map.get(
               Aikido.Dsl.Sensor.Info.sensor_options(Aikido.Dsl.SensorTest.FullSensor),
               :vsn
             ) == "1.0.0"
    end

    test "tags/1 defaults to []" do
      assert Map.get(
               Aikido.Dsl.Sensor.Info.sensor_options(Aikido.Dsl.SensorTest.MinimalSensor),
               :tags
             ) == []
    end

    test "description/1 returns nil when omitted" do
      assert Map.get(
               Aikido.Dsl.Sensor.Info.sensor_options(Aikido.Dsl.SensorTest.MinimalSensor),
               :description
             ) == nil
    end

    test "schema/1 round-trips a Ash field contract" do
      schema = Aikido.Dsl.Sensor.Info.schema(Aikido.Dsl.SensorTest.FullSensor)
      assert Ash.Type.ash_type?(schema)
      assert {:ok, %{interval: 5000}} = Aikido.Schema.cast(schema, %{interval: 5000})
    end

    test "schema/1 returns nil when omitted" do
      assert Aikido.Dsl.Sensor.Info.schema(Aikido.Dsl.SensorTest.MinimalSensor) == nil
    end

    test "Spark.Dsl.is?(mod, Aikido.Sensor) is true for sensor modules" do
      assert Spark.Dsl.is?(Aikido.Dsl.SensorTest.FullSensor, Aikido.Sensor)
      assert Spark.Dsl.is?(Aikido.Dsl.SensorTest.MinimalSensor, Aikido.Sensor)
    end
  end

  describe("default terminate/2") do
    nil

    test "default terminate/2 returns :ok" do
      assert Aikido.Dsl.SensorTest.TerminateSensor.terminate(:normal, %{}) == :ok
    end
  end

  describe("behaviour") do
    test "modules use Aikido.Sensor implement the @behaviour" do
      defmodule Elixir.Aikido.Dsl.SensorTest.BehaviourCheckSensor do
        @moduledoc false
        use Aikido.Sensor

        sensor do
          name "behaviour_check_sensor"
        end

        @impl Aikido.Sensor
        def init(_config, _ctx) do
          {:ok, %{}}
        end

        @impl Aikido.Sensor
        def handle_event(_event, state) do
          {:ok, state}
        end
      end

      behaviours =
        Aikido.Dsl.SensorTest.BehaviourCheckSensor.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Aikido.Sensor in behaviours
    end
  end
end
