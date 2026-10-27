defmodule Aikido.Inspector.History do
  @moduledoc """
  Bounded, redacted signal/state history for read-only agent inspection.

  Project live state with `project_agent_state/2` and execution events with
  `project_event/2` inside an observer selector. These functions apply native
  resource sensitivity metadata, redact credential and runtime fields, and
  bound retained values. Native Ash action spans are captured through telemetry.

  `record/6` appends a transition to a history from `new/0`. Its snapshot contains
  `:id` and `:inspected_state`; `path` is a list of display names. Supply the
  preceding projected state to compute the diff. History retains the latest
  100 transitions; applications own its lifetime and selected-event state.
  """
  @limit 100
  @private ~w(api_key authorization password secret access_token refresh_token actor tenant context __meta__ __metadata__ tracer_context prepared_tools tool_context run_scope tools_resume action_input changeset query private_vars)
  @private_names MapSet.new(@private)

  def project_state(state) do
    state
    |> __MODULE__.Redaction.typed_value()
    |> sanitize()
    |> __MODULE__.Bounds.limit()
  end

  def project_agent_state(state, resource),
    do:
      state
      |> __MODULE__.Redaction.agent_state(resource)
      |> sanitize()
      |> __MODULE__.Bounds.limit()

  def project_event(event, resource \\ nil) do
    data = __MODULE__.Redaction.signal_data(event.signal, resource)
    error = __MODULE__.Redaction.error(event.error, data)
    actions = __MODULE__.ActionTelemetry.actions(event.signal.id)

    %{
      signal:
        event.signal
        |> Map.take([:id, :type, :source, :subject, :data])
        |> Map.new(fn {key, value} ->
          value = if key == :data, do: data, else: value
          {key, project_state(value)}
        end),
      directives: event.directives |> Enum.take(30) |> Enum.map(&directive/1),
      directive_count: length(event.directives),
      actions: actions.entries,
      action_count: actions.count,
      error: project_state(error),
      error_message: error |> error_message() |> project_state()
    }
  end

  def record(history, snapshot, path, execution, before, pid \\ nil) do
    after_state = Map.get(snapshot, :inspected_state)
    sequence = history.sequence + 1

    entry = %{
      sequence: sequence,
      agent: Enum.join(path, " / "),
      agent_id: snapshot.id,
      agent_pid: if(is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()),
      time: DateTime.utc_now() |> DateTime.to_iso8601(),
      before: before,
      after: after_state,
      changes: diff(before, after_state),
      execution: execution
    }

    %{history | sequence: sequence, entries: Enum.take([entry | history.entries], @limit)}
  end

  def new, do: %{sequence: 0, entries: []}

  @doc "Readable explanation from a native error or an already projected historical error."
  def error_message(nil), do: nil
  def error_message(error) when is_binary(error), do: error

  def error_message(error) when is_map(error) do
    nested = Map.get(error, :errors) || Map.get(error, "errors")
    message = Map.get(error, :message) || Map.get(error, "message")
    members = Map.get(error, :members) || Map.get(error, "members")

    cond do
      is_list(nested) && nested != [] ->
        Enum.map_join(nested, "\n", &error_message/1)

      is_exception(error) ->
        Exception.message(error)

      is_binary(message) ->
        message

      is_list(members) && length(members) > 1 && hd(members) == List.last(members) ->
        members
        |> then(&Aikido.Team.Errors.DelegationCycle.exception(members: &1))
        |> Exception.message()

      true ->
        inspect(project_state(error), pretty: true, limit: 10)
    end
  end

  def error_message(error), do: inspect(project_state(error), pretty: true, limit: 10)

  def diff(before, after_state), do: diff(before, after_state, [])

  defp diff(value, value, _path), do: []

  defp diff(before, after_state, path) when is_map(before) and is_map(after_state) do
    (Map.keys(before) ++ Map.keys(after_state))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      diff(Map.get(before, key), Map.get(after_state, key), path ++ [to_string(key)])
    end)
  end

  defp diff(before, after_state, path),
    do: [%{path: Enum.join(path, "."), before: before, after: after_state}]

  defp directive(%module{} = descriptor) do
    %{
      type: inspect(module),
      fields: project_state(descriptor)
    }
  end

  defp sanitize(value), do: sanitize(value, 0)
  defp sanitize(_value, depth) when depth >= 8, do: "[depth limit]"
  defp sanitize(value, _depth) when is_function(value), do: "[function]"
  defp sanitize(value, _depth) when is_pid(value), do: "[process]"
  defp sanitize(value, _depth) when is_reference(value), do: "[reference]"

  defp sanitize(value, _depth) when is_binary(value) do
    cond do
      not String.valid?(value) -> "[binary data]"
      byte_size(value) > 4000 -> String.slice(value, 0, 4000) <> "… [truncated]"
      true -> value
    end
  end

  defp sanitize(%_{} = value, depth), do: value |> Map.from_struct() |> sanitize(depth)

  defp sanitize(value, depth) when is_map(value) do
    value
    |> limit_map_entries()
    |> Map.new(fn {key, value} ->
      name = key_name(key)
      {name, if(private?(name), do: "[redacted]", else: sanitize(value, depth + 1))}
    end)
  end

  defp sanitize(value, depth) when is_list(value) do
    Enum.map(Enum.take(value, 30), &sanitize(&1, depth + 1)) ++
      if(length(value) > 30, do: ["[list truncated]"], else: [])
  end

  defp sanitize({key, value}, depth) do
    name = key_name(key)
    [name, if(private?(name), do: "[redacted]", else: sanitize(value, depth + 1))]
  end

  defp sanitize(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> sanitize(depth + 1)

  defp sanitize(value, _depth) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp sanitize(value, _depth)
       when is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value), do: value

  defp sanitize(_value, _depth), do: "[unsupported value]"

  defp limit_map_entries(value) when map_size(value) <= 80, do: value

  defp limit_map_entries(value),
    do: value |> Enum.sort_by(fn {key, _} -> inspect(key) end) |> Enum.take(80)

  defp key_name(key) when is_binary(key) or is_atom(key), do: to_string(key)
  defp key_name(key), do: inspect(key, limit: 5)

  defp private?(name) do
    MapSet.member?(@private_names, String.downcase(name)) ||
      Regex.match?(~r/api.?key|secret|password|authorization|credential|(^|_)token($|_)/i, name)
  end
end
