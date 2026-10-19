defmodule Aikido.Util do
  @moduledoc """
  A collection of utility functions for the Aikido framework.

  This module provides various helper functions that are used throughout the Aikido framework,
  including:

  - ID generation
  - Name validation
  - Error handling
  - Logging utilities

  These utilities are designed to support common operations and maintain consistency
  across the Aikido ecosystem. They encapsulate frequently used patterns and provide
  a centralized location for shared functionality.

  Many of the functions in this module are used internally by other Aikido modules,
  but they can also be useful for developers building applications with Aikido.
  """

  alias Jido.Signal.ID, as: SignalID

  require Logger

  @name_regex ~r/^[a-zA-Z][a-zA-Z0-9_]*$/

  @doc """
  Generates a unique ID.
  """
  @spec generate_id() :: String.t()
  def generate_id, do: SignalID.generate!()

  @doc """
  Validates a slice name.

  The name must contain only letters, numbers, and underscores.

  ## Parameters

  - `name`: The name to validate.

  ## Returns

  - `{:ok, name}` if the name is valid.
  - `{:error, reason}` if the name is invalid.

  ## Examples

      iex> Aikido.Util.validate_name("valid_name_123")
      {:ok, "valid_name_123"}

      iex> Aikido.Util.validate_name("invalid-name")
      {:error, "The name must contain only letters, numbers, and underscores."}

  """
  @spec validate_name(any()) :: {:ok, String.t()} | {:error, Aikido.Error.ValidationError.t()}
  @spec validate_name(any(), keyword()) :: :ok | {:error, Aikido.Error.ValidationError.t()}
  def validate_name(name, opts \\ [])

  def validate_name(name, []) when is_binary(name) do
    if Regex.match?(@name_regex, name) do
      {:ok, name}
    else
      {:error,
       Aikido.Error.validation_error(
         "The name must start with a letter and contain only letters, numbers, and underscores.",
         field: :name
       )}
    end
  end

  def validate_name(name, _opts) when is_binary(name) do
    if Regex.match?(@name_regex, name) do
      :ok
    else
      {:error,
       Aikido.Error.validation_error(
         "The name must start with a letter and contain only letters, numbers, and underscores.",
         field: :name
       )}
    end
  end

  def validate_name(_, []) do
    {:error, Aikido.Error.validation_error("Invalid name format.", field: :name)}
  end

  def validate_name(_, _opts) do
    {:error, Aikido.Error.validation_error("Invalid name format.", field: :name)}
  end

  @valid_levels Logger.levels()

  @doc """
  Conditionally logs a message based on comparing threshold and message log levels.

  This function provides a way to conditionally log messages by comparing a threshold level
  against the message's intended log level. The message will only be logged if the threshold
  level is less than or equal to the message level.

  ## Parameters

  - `threshold_level`: The minimum log level threshold (e.g. :debug, :info, etc)
  - `message_level`: The log level for this specific message
  - `message`: The message to potentially log
  - `opts`: Additional options passed to Logger.log/3

  ## Returns

  - `:ok` in all cases

  ## Examples

      # Will log since :info >= :info
      iex> cond_log(:info, :info, "test message")
      :ok

      # Won't log since :info > :debug
      iex> cond_log(:info, :debug, "test message")
      :ok

      # Will log since :debug <= :info
      iex> cond_log(:debug, :info, "test message")
      :ok
  """
  @spec cond_log(Logger.level(), Logger.level(), Logger.message(), keyword()) :: :ok
  def cond_log(threshold_level, message_level, message, opts \\ []) do
    cond do
      threshold_level not in @valid_levels or message_level not in @valid_levels ->
        :ok

      Logger.compare_levels(threshold_level, message_level) in [:lt, :eq] ->
        Logger.log(message_level, message, opts)

      true ->
        :ok
    end
  end
end
