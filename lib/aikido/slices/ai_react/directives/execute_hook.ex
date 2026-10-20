defmodule Aikido.Slices.AiReact.Directives.ExecuteHook do
  @moduledoc "Runs one bounded Lua hook and returns its result through a signal."
  use Aikido.Directive

  typed_struct do
    field :hook, :struct do
      description "Validated Lua hook configuration executed within the configured resource limits."
      constraints instance_of: Aikido.Slices.AiReact.Hooks.Hook
      allow_nil? false
    end

    field :event, :map do
      description "Lifecycle event data made available to the Lua script."
      allow_nil? false
    end

    field :token, :integer do
      description "Gate identity used to correlate this hook result with the waiting pipeline step."
      allow_nil? false
    end

    field :request_id, :string do
      description "AI run identity carried into hook callbacks and completion signals."
      allow_nil? false
    end
  end

  @impl true
  def exec(directive, signal, runtime) do
    pid = self()

    payload = %{
      request_id: directive.request_id,
      token: directive.token,
      name: directive.hook.name,
      mode: directive.hook.mode
    }

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        result =
          evaluate(directive.hook, directive.event, pid, directive.request_id, signal)

        Aikido.Signal.new!("ai.react.hook.completed", Map.put(payload, :result, result))
      end,
      payload: payload,
      error_type: "ai.react.hook.completed"
    }

    Aikido.Directives.AsyncTask.exec(task, signal, runtime)
  end

  @doc false
  def evaluate(hook, event, pid, request_id, source_signal \\ nil) do
    lua =
      Lua.new(
        max_instructions: hook.max_instructions,
        max_call_depth: hook.max_call_depth,
        max_string_bytes: hook.max_string_bytes
      )
      |> Lua.set!([:event], AshLua.Encoder.encode_result(event))
      |> install_request(hook, event, request_id)

    # Only async hooks get fire-and-forget signal helpers. Both modes can
    # request a response; the owning action still applies the final decision.
    lua =
      if hook.mode == :async,
        do: install_signals(lua, pid, request_id, hook.name, source_signal),
        else: lua

    {values, _lua} = Lua.eval!(lua, hook.script)
    values = Enum.map(values, &AshLua.Encoder.decode_input/1)

    if hook.mode == :sync do
      case values do
        [] ->
          Ash.Type.cast_input(Aikido.Slices.AiReact.Hooks.Decision, %{})

        [nil] ->
          Ash.Type.cast_input(Aikido.Slices.AiReact.Hooks.Decision, %{})

        [value] when is_map(value) ->
          Ash.Type.cast_input(Aikido.Slices.AiReact.Hooks.Decision, value)

        _ ->
          {:error, "hook must return nil or a decision table"}
      end
    else
      {:ok, nil}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp install_signals(lua, pid, request_id, name, source_signal) do
    lua
    |> Lua.set!([:aikido, :send_context], fn args, state ->
      [text] = Lua.decode_list!(state, args)
      true = is_binary(text)

      signal =
        Aikido.Signal.new!("ai.react.hook.context", %{
          request_id: request_id,
          name: name,
          text: text
        })

      signal = if source_signal, do: Aikido.Signal.inherit(signal, source_signal), else: signal
      :ok = Aikido.AgentServer.cast(pid, signal)

      {[true], state}
    end)
    |> Lua.set!([:aikido, :send_signal], fn args, state ->
      [type, data] = Lua.decode_list!(state, args)
      data = AshLua.Encoder.decode_input(data)
      true = is_binary(type) and is_map(data)
      # Internal ReAct result signals are reserved; hooks cannot forge model,
      # tool or gate completions through this capability.
      false = String.starts_with?(type, "ai.react.")
      payload = data |> Map.delete("request_id") |> Map.put(:request_id, request_id)
      signal = Aikido.Signal.new!(type, payload)
      signal = if source_signal, do: Aikido.Signal.inherit(signal, source_signal), else: signal
      :ok = Aikido.AgentServer.cast(pid, signal)
      {[true], state}
    end)
  end

  defp install_request(lua, hook, event, request_id) do
    Lua.set!(lua, [:aikido, :request], fn args, vm ->
      [type, payload] = Lua.decode_list!(vm, args)
      payload = AshLua.Encoder.decode_input(payload)
      true = is_binary(type) and is_map(payload)

      result =
        if hook.request do
          hook.request.(%{type: type, payload: payload}, %{
            hook: hook.name,
            request_id: request_id,
            event: event
          })
        else
          {:error, :request_callback_not_configured}
        end

      values =
        case result do
          {:ok, response} -> [AshLua.Encoder.encode_result(response), nil]
          {:error, reason} -> [nil, %{message: inspect(reason)}]
          other -> [nil, %{message: "Invalid request callback result: #{inspect(other)}"}]
        end

      Lua.encode_list!(vm, values)
    end)
  end
end
