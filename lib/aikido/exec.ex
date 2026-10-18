defmodule Aikido.Exec do
  @moduledoc """
  Action execution engine with modular architecture for robust action processing.

  This module provides the core execution interface for Aikido Actions with specialized
  helper modules handling specific concerns:

  - **Aikido.Exec.Telemetry** - Logging and telemetry events
  - **Aikido.Exec.Retry** - Exponential backoff and retry logic
  - **Aikido.Exec.Async** - Asynchronous execution management
  - **Aikido.Exec.Chain** - Sequential action execution
  - **Aikido.Exec.Closure** - Action closures with pre-applied context

  ## Core Features

  - Synchronous and asynchronous action execution
  - Automatic retries with exponential backoff
  - Timeout handling for long-running actions
  - Parameter and context normalization
  - Structured error handling
  - Telemetry integration for monitoring and tracing
  - Action cancellation and cleanup

  ## Usage

  Basic action execution:

      Aikido.Exec.run(MyAction, %{param1: "value"}, %{context_key: "context_value"})

  Asynchronous execution:

      async_ref = Aikido.Exec.run_async(MyAction, params, context)
      # ... do other work ...
      result = Aikido.Exec.await(async_ref)

  Define actions on their owning Ash resource with `Ash.Resource.Actions.Implementation` callbacks.
  """
  use Private

  alias Aikido.Error
  alias Aikido.Exec.Async
  alias Aikido.Exec.Retry
  alias Aikido.Exec.Supervisors
  alias Aikido.Exec.Telemetry
  alias Aikido.Instruction

  require Logger

  @default_timeout 30_000
  @deadline_key :__aikido_deadline_ms__

  # Helper functions to get configuration values with fallbacks
  defp get_default_timeout,
    do: resolve_non_neg_integer_config(:default_timeout, @default_timeout)

  defp resolve_non_neg_integer_config(key, fallback) do
    case Application.get_env(:aikido_action, key, fallback) do
      value when is_integer(value) and value >= 0 ->
        value

      invalid ->
        Logger.warning(
          "Invalid :aikido_action config for #{inspect(key)}: #{inspect(invalid)}. " <>
            "Expected a non-negative integer; using fallback #{fallback}."
        )

        fallback
    end
  end

  @type action :: module()
  @type params :: map()
  @type context :: map()
  @type run_opts :: [timeout: non_neg_integer(), aikido: atom()]
  @type async_ref :: %{
          required(:ref) => reference(),
          required(:pid) => pid(),
          optional(:owner) => pid(),
          optional(:monitor_ref) => reference()
        }

  # Execution result types — see ADR 0018
  @type exec_success :: {:ok, map(), [Aikido.Directives.t()]}
  @type exec_error :: {:error, term()}

  @type exec_result :: exec_success | exec_error

  @doc """
  Executes a Action synchronously with the given parameters and context.

  ## Parameters

  - `action`: The module implementing the Action behavior.
  - `params`: A map of input parameters for the Action.
  - `context`: A map providing additional context for the Action execution.
  - `opts`: Options controlling the execution:
    - `:timeout` - Maximum time (in ms) allowed for the Action to complete (configurable via `:aikido_action, :default_timeout`).
    - `:max_retries` - Maximum number of retry attempts (configurable via `:aikido_action, :default_max_retries`).
    - `:backoff` - Initial backoff time in milliseconds, doubles with each retry (configurable via `:aikido_action, :default_backoff`).
    - `:log_level` - Override the global Logger level for this specific action. Accepts #{inspect(Logger.levels())}.
    - `:aikido` - Optional instance name for isolation. Routes execution through instance-scoped supervisors (e.g., `MyApp.Aikido.TaskSupervisor`).

  ## Returns

  - `{:ok, slice, [directive]}` on success — always a 3-tuple, even when no
    directives are emitted.
  - `{:error, reason}` if an error occurs during execution.

  ## Examples

      iex> Aikido.Exec.run(MyAction, %{input: "value"}, %{user_id: 123})
      {:ok, %{result: "processed value"}, []}

      iex> Aikido.Exec.run(MyAction, %{invalid: "input"}, %{}, timeout: 1000)
      {:error, %Ash.Error.Invalid{}}

      iex> Aikido.Exec.run(MyAction, %{input: "value"}, %{}, log_level: :debug)
      {:ok, %{result: "processed value"}, []}

  """
  @spec run(Instruction.t()) :: exec_result()
  @spec run(action(), params(), context(), run_opts()) :: exec_result()
  def run(%Instruction{} = instruction) do
    run(
      instruction.action,
      instruction.params,
      instruction.context,
      instruction.opts
    )
  end

  def run(action, params \\ %{}, context \\ %{}, opts \\ [])

  def run(action, params, context, opts)
      when (is_atom(action) or is_tuple(action)) and is_list(opts) do
    log_level = Keyword.get(opts, :log_level, :info)

    with {:ok, normalized_params} <- normalize_params(params),
         {:ok, normalized_context} <- normalize_context(context),
         :ok <- validate_action(action) do
      Telemetry.cond_log_start(log_level, action, normalized_params, normalized_context)

      do_run_with_retry(action, normalized_params, normalized_context, opts)
    else
      {:error, reason} ->
        Telemetry.cond_log_failure(log_level, inspect(reason))
        {:error, reason}
    end
  rescue
    e in [FunctionClauseError, BadArityError, BadFunctionError] ->
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_function_error(log_level, e)

      {:error,
       Error.validation_error("Invalid action module: #{Telemetry.extract_safe_error_message(e)}")}

    e ->
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_unexpected_error(log_level, e)

      {:error,
       Error.internal_error(
         "An unexpected error occurred: #{Telemetry.extract_safe_error_message(e)}"
       )}
  catch
    kind, reason ->
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_caught_error(log_level, reason)

      {:error, Error.internal_error("Caught #{kind}: #{inspect(reason)}")}
  end

  def run(action, _params, _context, _opts) do
    {:error, Error.validation_error("Expected action to be a module, got: #{inspect(action)}")}
  end

  @doc """
  Executes a Action asynchronously with the given parameters and context.

  This function immediately returns a reference that can be used to await the result
  or cancel the action.

  **Note**: This approach integrates with OTP by spawning tasks under a `Task.Supervisor`.
  Make sure `{Task.Supervisor, name: Aikido.Action.TaskSupervisor}` is part of your supervision tree.

  ## Parameters

  - `action`: The module implementing the Action behavior.
  - `params`: A map of input parameters for the Action.
  - `context`: A map providing additional context for the Action execution.
  - `opts`: Options controlling the execution (same as `run/4`).

  ## Returns

  An `async_ref` map containing:
  - `:ref` - A unique reference for this async action.
  - `:pid` - The PID of the process executing the Action.
  - `:owner` - The PID of the caller that started the async action.

  ## Examples

      iex> async_ref = Aikido.Exec.run_async(MyAction, %{input: "value"}, %{user_id: 123})
      %{ref: #Reference<0.1234.5678>, pid: #PID<0.234.0>}

      iex> result = Aikido.Exec.await(async_ref)
      {:ok, %{result: "processed value"}}
  """
  @spec run_async(action(), params(), context(), run_opts()) :: async_ref()
  def run_async(action, params \\ %{}, context \\ %{}, opts \\ []) do
    Async.start(action, params, context, opts)
  end

  @doc """
  Waits for the result of an asynchronous Action execution.

  ## Parameters

  - `async_ref`: The reference returned by `run_async/4`.
  - `timeout`: Maximum time (in ms) to wait for the result (default: 5000).

  ## Returns

  - `{:ok, result}` if the Action executes successfully.
  - `{:error, reason}` if an error occurs during execution or if the action times out.
  - `{:error, %Aikido.Error.ValidationError{}}` when awaited by a non-owner process.

  ## Examples

      iex> async_ref = Aikido.Exec.run_async(MyAction, %{input: "value"})
      iex> Aikido.Exec.await(async_ref, 10_000)
      {:ok, %{result: "processed value"}}

      iex> async_ref = Aikido.Exec.run_async(SlowAction, %{input: "value"})
      iex> Aikido.Exec.await(async_ref, 100)
      {:error, %Aikido.Error.TimeoutError{}}
  """
  @spec await(async_ref()) :: exec_result
  def await(async_ref), do: Async.await(async_ref)

  @doc """
  Awaits the completion of an asynchronous Action with a custom timeout.

  ## Parameters

  - `async_ref`: The async reference returned by `run_async/4`.
  - `timeout`: Maximum time to wait in milliseconds.

  ## Returns

  - `{:ok, result}` if the Action completes successfully.
  - `{:error, reason}` if an error occurs or timeout is reached.
  """
  @spec await(async_ref(), timeout()) :: exec_result
  def await(async_ref, timeout), do: Async.await(async_ref, timeout)

  @doc """
  Cancels a running asynchronous Action execution.

  ## Parameters

  - `async_ref`: The reference returned by `run_async/4`, or just the PID of the process to cancel.

  ## Returns

  - `:ok` if the cancellation was successful.
  - `{:error, reason}` if the cancellation failed or the input was invalid.
  - `{:error, %Aikido.Error.ValidationError{}}` when cancelled by a non-owner process.

  ## Examples

      iex> async_ref = Aikido.Exec.run_async(LongRunningAction, %{input: "value"})
      iex> Aikido.Exec.cancel(async_ref)
      :ok

      iex> Aikido.Exec.cancel("invalid")
      {:error, %Aikido.Error.ValidationError{}}
  """
  @spec cancel(async_ref() | pid()) :: :ok | exec_error
  def cancel(async_ref_or_pid), do: Async.cancel(async_ref_or_pid)

  # Private functions are exposed to the test suite
  private do
    defp validate_action(reference) do
      if Aikido.ActionRef.valid?(reference),
        do: :ok,
        else: {:error, Error.validation_error("Invalid native Ash action: #{inspect(reference)}")}
    end

    @spec normalize_params(params()) :: {:ok, map()} | {:error, Exception.t()}
    defp normalize_params(%_{} = error) when is_exception(error), do: {:error, error}
    defp normalize_params(params) when is_map(params), do: {:ok, params}
    defp normalize_params(params) when is_list(params), do: {:ok, Map.new(params)}
    defp normalize_params({:ok, params}) when is_map(params), do: {:ok, params}
    defp normalize_params({:ok, params}) when is_list(params), do: {:ok, Map.new(params)}
    defp normalize_params({:error, reason}), do: {:error, Error.validation_error(reason)}

    defp normalize_params(params),
      do: {:error, Error.validation_error("Invalid params type: #{inspect(params)}")}

    @spec normalize_context(context()) :: {:ok, map()} | {:error, Exception.t()}
    defp normalize_context(context) when is_map(context), do: {:ok, context}
    defp normalize_context(context) when is_list(context), do: {:ok, Map.new(context)}

    defp normalize_context(context),
      do: {:error, Error.validation_error("Invalid context type: #{inspect(context)}")}

    @spec do_run_with_retry(action(), params(), context(), run_opts()) :: exec_result
    defp do_run_with_retry(action, params, context, opts) do
      retry_opts = Retry.extract_retry_opts(opts)
      max_retries = retry_opts[:max_retries]
      backoff = retry_opts[:backoff]
      do_run_with_retry(action, params, context, opts, 0, max_retries, backoff)
    end

    @spec do_run_with_retry(
            action(),
            params(),
            context(),
            run_opts(),
            non_neg_integer(),
            non_neg_integer(),
            non_neg_integer()
          ) :: exec_result
    defp do_run_with_retry(action, params, context, opts, retry_count, max_retries, backoff) do
      case do_run(action, params, context, opts) do
        {:ok, result, dirs} ->
          {:ok, result, dirs}

        {:error, reason} ->
          maybe_retry(
            action,
            params,
            context,
            opts,
            retry_count,
            max_retries,
            backoff,
            {:error, reason}
          )
      end
    end

    defp maybe_retry(
           action,
           params,
           context,
           opts,
           retry_count,
           max_retries,
           initial_backoff,
           error
         ) do
      if Retry.should_retry?(error, retry_count, max_retries, opts) do
        Retry.execute_retry(action, retry_count, max_retries, initial_backoff, opts, fn ->
          do_run_with_retry(
            action,
            params,
            context,
            opts,
            retry_count + 1,
            max_retries,
            initial_backoff
          )
        end)
      else
        error
      end
    end

    @spec do_run(action(), params(), context(), run_opts()) :: exec_result
    defp do_run(action, params, context, opts) do
      telemetry = Keyword.get(opts, :telemetry, :full)

      with {:ok, timeout, budgeted_context} <- resolve_timeout_budget(context, opts) do
        result =
          case telemetry do
            :silent ->
              if opts == [] do
                execute_action_with_timeout(action, params, budgeted_context, timeout)
              else
                execute_action_with_timeout(action, params, budgeted_context, timeout, opts)
              end

            _ ->
              span_metadata = %{
                action: action,
                params: params,
                context: budgeted_context
              }

              :telemetry.span(
                [:aikido, :action],
                span_metadata,
                fn ->
                  result =
                    execute_action_with_timeout(action, params, budgeted_context, timeout, opts)

                  {result, %{}}
                end
              )
          end

        case result do
          {:ok, _result, _dirs} = success ->
            success

          {:error, _} = error ->
            error
        end
      end
    end

    @spec execute_action_with_timeout(
            action(),
            params(),
            context(),
            non_neg_integer(),
            run_opts()
          ) :: exec_result
    defp execute_action_with_timeout(action, params, context, timeout, opts)

    defp execute_action_with_timeout(action, params, context, 0, opts) do
      execute_action(action, params, context, opts)
    end

    @dialyzer {:nowarn_function, execute_action_with_timeout: 5}
    defp execute_action_with_timeout(action, params, context, timeout, opts)
         when is_integer(timeout) and timeout > 0 do
      # Get the current process's group leader for IO routing
      current_gl = Process.group_leader()

      # Resolve supervisor based on aikido: option (defaults to global)
      task_sup = Supervisors.task_supervisor(opts)

      parent = self()
      ref = make_ref()

      # Spawn process under the supervisor and send the result back explicitly.
      # This avoids relying on Task.yield/2 behavior/typing (Elixir 1.18+).
      {:ok, pid} =
        Task.Supervisor.start_child(task_sup, fn ->
          # Use the parent's group leader to ensure IO is properly captured
          Process.group_leader(self(), current_gl)

          result = execute_action(action, params, context, opts)
          send(parent, {:execute_action_result, ref, result})
        end)

      monitor_ref = Process.monitor(pid)

      # Wait for completion, crash, or timeout.
      result =
        receive do
          {:execute_action_result, ^ref, result} ->
            Process.demonitor(monitor_ref, [:flush])
            {:ok, result}

          {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
            # If the process exited normally, a result message may still be in flight.
            case reason do
              :normal ->
                receive do
                  {:execute_action_result, ^ref, result} -> {:ok, result}
                after
                  0 -> {:exit, reason}
                end

              _ ->
                {:exit, reason}
            end
        after
          timeout ->
            _ = Task.Supervisor.terminate_child(task_sup, pid)

            # Best-effort wait for termination to avoid leaking processes in slow CI runners.
            receive do
              {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
            after
              100 -> :ok
            end

            Process.demonitor(monitor_ref, [:flush])

            # Flush any late result message (race with timeout).
            receive do
              {:execute_action_result, ^ref, _result} -> :ok
            after
              0 -> :ok
            end

            :timeout
        end

      case result do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error,
           Error.execution_error("Task exited: #{inspect(reason)}", %{
             reason: reason,
             action: action
           })}

        :timeout ->
          {:error,
           Error.timeout_error(
             "Action #{inspect(action)} timed out after #{timeout}ms",
             %{
               timeout: timeout,
               action: action
             }
           )}
      end
    end

    defp execute_action_with_timeout(action, params, context, _timeout, opts) do
      execute_action_with_timeout(action, params, context, get_default_timeout(), opts)
    end

    @spec execute_action_with_timeout(action(), params(), context(), non_neg_integer()) ::
            exec_result
    defp execute_action_with_timeout(action, params, context, timeout) do
      execute_action_with_timeout(action, params, context, timeout, [])
    end

    defp resolve_timeout_budget(context, opts) do
      timeout = resolve_timeout_opt(opts)
      existing_deadline = Map.get(context, @deadline_key)

      if timeout == 0 and not is_integer(existing_deadline) do
        {:ok, timeout, context}
      else
        now = System.monotonic_time(:millisecond)

        deadline =
          cond do
            is_integer(existing_deadline) and timeout > 0 ->
              min(existing_deadline, now + timeout)

            is_integer(existing_deadline) ->
              existing_deadline

            timeout > 0 ->
              now + timeout

            true ->
              nil
          end

        case deadline do
          deadline_ms when is_integer(deadline_ms) ->
            apply_deadline_budget(deadline_ms, now, timeout, context)

          _ ->
            {:ok, timeout, context}
        end
      end
    end

    defp apply_deadline_budget(deadline_ms, now, timeout, context) do
      remaining = deadline_ms - now

      if remaining <= 0 do
        {:error,
         Error.timeout_error("Execution deadline exceeded before action dispatch", %{
           deadline_ms: deadline_ms,
           now_ms: now
         })}
      else
        effective_timeout = if timeout == 0, do: remaining, else: min(timeout, remaining)
        {:ok, effective_timeout, Map.put(context, @deadline_key, deadline_ms)}
      end
    end

    defp resolve_timeout_opt(opts) do
      case Keyword.get(opts, :timeout, get_default_timeout()) do
        timeout when is_integer(timeout) and timeout >= 0 -> timeout
        _invalid -> get_default_timeout()
      end
    end

    @spec execute_action(action(), params(), context(), run_opts()) :: exec_result
    defp execute_action(action, params, context, opts) do
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_execution_debug(log_level, action, params, context)

      {signal, slice, action_opts, ctx} = build_action_context(action, params, context)

      {resource, name} = Aikido.ActionRef.normalize(action)
      definition = Ash.Resource.Info.action(resource, name)
      runtime = Map.merge(ctx, %{signal: signal, action_opts: action_opts})

      arguments =
        if Enum.any?(definition.arguments, &(&1.name == :data)),
          do: %{data: params, state: slice},
          else: Map.put(params, :state, slice)

      ash_opts = Ash.Scope.to_opts(ctx, context: %{aikido: runtime})

      input =
        Ash.ActionInput.for_action(
          resource,
          name,
          arguments,
          Keyword.put(ash_opts, :skip_unknown_inputs, [:*])
        )

      case Ash.run_action(input, ash_opts) do
        {:ok, result} ->
          case Aikido.ActionResult.new(result) do
            {:ok, result} -> {:ok, result.state, result.directives}
            {:error, error} -> {:error, Ash.Error.to_error_class(error)}
          end

        {:error, error} ->
          {:error, error}
      end
      |> handle_action_result(action, log_level, opts)
    rescue
      e ->
        handle_action_exception(e, __STACKTRACE__, action, opts)
    end

    # Scope the resource action to its slice and preserve the signal envelope.
    # Native Ash arguments own casting and defaults; runtime metadata is carried
    # separately in input.context.aikido.
    defp build_action_context(action, params, ctx_in) do
      signal =
        case Map.get(ctx_in, :signal) do
          %Jido.Signal{} = sig -> %{sig | data: ensure_map(params)}
          _ -> synthesize_signal(action, params)
        end

      slice = Map.get(ctx_in, :state, %{})
      action_opts = Map.get(ctx_in, :action_opts, %{})

      ctx_from_signal =
        case signal do
          %Jido.Signal{} -> Aikido.SignalCtx.ctx(signal)
          _ -> %{}
        end

      ctx =
        ctx_from_signal
        |> Map.merge(Map.get(ctx_in, :ctx, %{}))
        |> maybe_put(:agent, Map.get(ctx_in, :agent))
        |> maybe_put(:agent_server_pid, Map.get(ctx_in, :agent_server_pid))
        |> maybe_put(:slice_path, Map.get(ctx_in, :slice_path))
        |> maybe_put(:slice_config, Map.get(ctx_in, :slice_config))

      {signal, slice, action_opts, ctx}
    end

    defp synthesize_signal(action, params) do
      type = action |> Aikido.ActionRef.definition() |> Map.fetch!(:name) |> to_string()

      data = ensure_map(params)

      case Jido.Signal.new(%{type: type, data: data, source: "/aikido/exec"}) do
        {:ok, signal} -> signal
        _ -> nil
      end
    end

    defp ensure_map(map) when is_map(map), do: map

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    # Per ADR 0018, actions return `{:ok, slice, [directive]}` or
    # `{:error, reason}`. Always a 3-tuple on success, with the directive
    # list defaulting to []. Anything else is rejected as a contract
    # violation with a structured ExecutionError.

    defp handle_action_result({:ok, result, dirs}, action, log_level, _opts) do
      log_success(action, result, log_level, List.wrap(dirs))
    end

    defp handle_action_result({:error, %_{} = error}, action, log_level, _opts)
         when is_exception(error) do
      Telemetry.cond_log_error(log_level, action, error)
      {:error, error}
    end

    defp handle_action_result({:error, reason}, action, log_level, _opts) do
      Telemetry.cond_log_error(log_level, action, reason)
      {message, details} = extract_error_fields(reason)
      {:error, Error.execution_error(message, details)}
    end

    defp handle_action_result(unexpected_result, action, log_level, _opts) do
      error = Error.execution_error("Unexpected return shape: #{inspect(unexpected_result)}")
      Telemetry.cond_log_error(log_level, action, error)
      {:error, error}
    end

    defp extract_error_fields(%{message: message} = reason) when is_binary(message) do
      {message, Map.delete(reason, :message)}
    end

    defp extract_error_fields(%{message: message} = reason) do
      {inspect(message), Map.delete(reason, :message)}
    end

    defp extract_error_fields(reason) when is_binary(reason), do: {reason, %{}}
    defp extract_error_fields(reason) when is_atom(reason), do: {Atom.to_string(reason), %{}}
    defp extract_error_fields(reason) when is_map(reason), do: {inspect(reason), reason}
    defp extract_error_fields(reason), do: {inspect(reason), %{}}

    defp log_success(action, result, log_level, dirs) do
      Telemetry.cond_log_end(log_level, action, {:ok, result, dirs})
      {:ok, result, dirs}
    end

    # Handle exceptions raised during action execution
    defp handle_action_exception(e, stacktrace, action, opts) do
      log_level = Keyword.get(opts, :log_level, :info)
      Telemetry.cond_log_error(log_level, action, e)

      error_message = build_exception_message(e, action)

      {:error,
       Error.execution_error(error_message, %{
         original_exception: e,
         action: action,
         stacktrace: stacktrace
       })}
    end

    defp build_exception_message(%RuntimeError{} = e, action) do
      "Server error in #{inspect(action)}: #{Telemetry.extract_safe_error_message(e)}"
    end

    defp build_exception_message(%ArgumentError{} = e, action) do
      "Argument error in #{inspect(action)}: #{Telemetry.extract_safe_error_message(e)}"
    end

    defp build_exception_message(e, action) do
      "An unexpected error occurred during execution of #{inspect(action)}: #{inspect(e)}"
    end
  end
end
