defmodule Aikido.Debug do
  @moduledoc """
  Per-instance debug mode for Aikido agents.

  Provides a single entrypoint to control observability verbosity
  at runtime, scoped to a specific Aikido instance.

  ## Debug Levels

  - `:off` - No debug overrides, uses configured defaults
  - `:on` - Developer-friendly verbosity (debug logging and the runtime event buffer)
  - `:verbose` - Maximum detail (trace logging and the runtime event buffer)

  ## Usage

      # A named runtime uses the shared debug API
      Aikido.Debug.enable(MyApp.Aikido, :on)
      Aikido.Debug.enable(MyApp.Aikido, :verbose)
      Aikido.Debug.disable(MyApp.Aikido)
      Aikido.Debug.level(MyApp.Aikido)          # => :off

      # Default runtime
      Aikido.Debug.enable(Aikido.Default, :on)
  """

  @type level :: :off | :on | :verbose
  @type instance :: atom()

  @on_overrides %{telemetry_log_level: :debug}
  @verbose_overrides %{telemetry_log_level: :trace}

  @spec enable(instance(), level()) :: :ok
  def enable(instance, level \\ :on)

  def enable(instance, :off), do: disable(instance)

  def enable(instance, level) when level in [:on, :verbose] do
    overrides = build_overrides(level)

    :persistent_term.put({:aikido_debug, instance}, %{level: level, overrides: overrides})
    :ok
  end

  @spec disable(instance()) :: :ok
  def disable(instance) do
    :persistent_term.erase({:aikido_debug, instance})
    :ok
  end

  @spec level(instance()) :: level()
  def level(instance) do
    case :persistent_term.get({:aikido_debug, instance}, nil) do
      nil -> :off
      %{level: level} -> level
    end
  end

  @spec enabled?(instance()) :: boolean()
  def enabled?(instance) do
    level(instance) != :off
  end

  @spec override(instance(), atom()) :: term() | nil
  def override(instance, key) do
    case :persistent_term.get({:aikido_debug, instance}, nil) do
      nil -> nil
      %{overrides: overrides} -> Map.get(overrides, key)
    end
  end

  @spec maybe_enable_from_config(atom(), instance()) :: :ok
  def maybe_enable_from_config(otp_app, instance) do
    config = Application.get_env(otp_app, instance, [])

    case Keyword.get(config, :debug) do
      true -> enable(instance, :on)
      :verbose -> enable(instance, :verbose)
      _ -> disable(instance)
    end
  end

  @spec status(instance()) :: map()
  def status(instance) do
    case :persistent_term.get({:aikido_debug, instance}, nil) do
      nil -> %{level: :off, overrides: %{}}
      state -> state
    end
  end

  defp build_overrides(:on), do: @on_overrides
  defp build_overrides(:verbose), do: @verbose_overrides
end
