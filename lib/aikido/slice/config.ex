defmodule Aikido.Slice.Config do
  @moduledoc """
  Resolves and validates slice configuration.

  Config resolution merges three sources (in order of precedence):
  1. Per-agent overrides (highest priority)
  2. Application environment config (`Application.get_env(otp_app, slice_module)`)
  3. Default values from the slice's config_schema (lowest priority)
  """

  @doc """
  Resolves configuration for a slice module by merging app env with overrides.
  """
  @spec resolve_config(module(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_config(slice_module, overrides \\ %{}) do
    base_config = get_app_env_config(slice_module)
    merged_config = Map.merge(base_config, overrides)

    validate_config(slice_module, merged_config)
  end

  @doc """
  Like `resolve_config/2` but raises on validation errors.
  """
  @spec resolve_config!(module(), map()) :: map()
  def resolve_config!(slice_module, overrides \\ %{}) do
    case resolve_config(slice_module, overrides) do
      {:ok, config} ->
        config

      {:error, errors} ->
        raise ArgumentError,
              "Config validation failed for #{inspect(slice_module)}: #{inspect(errors)}"
    end
  end

  @doc false
  @spec get_app_env_config(module()) :: map()
  def get_app_env_config(slice_module) do
    otp_app = Map.get(Aikido.Slice.Info.slice_options(slice_module), :otp_app)

    if otp_app do
      Application.get_env(otp_app, slice_module, %{})
      |> normalize_to_map()
    else
      %{}
    end
  end

  defp normalize_to_map(config) when is_list(config), do: Map.new(config)
  defp normalize_to_map(config) when is_map(config), do: config
  defp normalize_to_map(_), do: %{}

  defp validate_config(slice_module, config) do
    case Aikido.Slice.Info.config_schema(slice_module) do
      [] ->
        {:ok, config}

      fields ->
        values =
          Map.new(fields, fn field ->
            value =
              case Map.fetch(config, field.name) do
                {:ok, value} ->
                  value

                :error ->
                  Map.get_lazy(config, to_string(field.name), fn ->
                    resolve_default(field.default)
                  end)
              end

            {field.name, value}
          end)

        constraints =
          Enum.map(fields, fn field ->
            {field.name, Map.to_list(Map.take(field, [:type, :constraints, :allow_nil?]))}
          end)

        with {:ok, constraints} <- Ash.Type.init(:map, fields: constraints),
             {:ok, values} <- Ash.Type.cast_input(:map, values, constraints),
             {:ok, values} <- Ash.Type.apply_constraints(:map, values, constraints) do
          {:ok, values}
        else
          {:error, errors} ->
            Ash.Type.CompositeTypeHelpers.convert_errors_to_invalid_attributes(errors)
        end
    end
  end

  defp resolve_default(fun) when is_function(fun, 0), do: fun.()
  defp resolve_default({module, function, args}), do: apply(module, function, args)
  defp resolve_default(value), do: value
end
