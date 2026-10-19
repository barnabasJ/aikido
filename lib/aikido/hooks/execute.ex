defmodule Aikido.Hooks.Execute do
  @moduledoc "Runs one bounded Lua hook and returns its result through a signal."
  use Aikido.Directive

  typed_struct do
    field :hook, :struct, constraints: [instance_of: Aikido.Hooks.Hook], allow_nil?: false
    field :event, :map, allow_nil?: false
    field :token, :integer, allow_nil?: false
    field :request_id, :string, allow_nil?: false
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
        result = evaluate(directive.hook, directive.event, pid, directive.request_id)
        Jido.Signal.new!("ai.react.hook.completed", Map.put(payload, :result, result))
      end,
      payload: payload,
      error_type: "ai.react.hook.completed"
    }

    Aikido.Directives.AsyncTask.exec(task, signal, runtime)
  end

  @doc false
  def evaluate(hook, event, pid, request_id) do
    lua =
      Lua.new(
        max_instructions: hook.max_instructions,
        max_call_depth: hook.max_call_depth,
        max_string_bytes: hook.max_string_bytes
      )
      |> Lua.set!([:event], AshLua.Encoder.encode_result(event))

    # Only async hooks can emit. Sync decisions are returned to the owning
    # action, so a denied gate cannot have already sent application signals.
    lua = if hook.mode == :async, do: install_signals(lua, pid, request_id, hook.name), else: lua
    {values, _lua} = Lua.eval!(lua, hook.script)
    values = Enum.map(values, &AshLua.Encoder.decode_input/1)

    if hook.mode == :sync do
      case values do
        [] -> Ash.Type.cast_input(Aikido.Hooks.Decision, %{})
        [nil] -> Ash.Type.cast_input(Aikido.Hooks.Decision, %{})
        [value] when is_map(value) -> Ash.Type.cast_input(Aikido.Hooks.Decision, value)
        _ -> {:error, "hook must return nil or a decision table"}
      end
    else
      {:ok, nil}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp install_signals(lua, pid, request_id, name) do
    lua
    |> Lua.set!([:aikido, :send_context], fn args, state ->
      [text] = Lua.decode_list!(state, args)
      true = is_binary(text)

      :ok =
        Aikido.AgentServer.cast(
          pid,
          Jido.Signal.new!("ai.react.hook.context", %{
            request_id: request_id,
            name: name,
            text: text
          })
        )

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
      :ok = Aikido.AgentServer.cast(pid, Jido.Signal.new!(type, payload))
      {[true], state}
    end)
  end
end
