defmodule Aikido.Signal.Call do
  @moduledoc """
  Synchronous request / reply over signals.

  `Aikido.AgentServer.state/3` and `Aikido.AgentServer.call/4` already cross
  the boundary safely (every call hands a selector that decides what is
  exposed). This primitive solves the *different* problem of letting the
  agent author decide the answer's shape: the caller dispatches a query
  signal, the agent routes it to an action that produces an answer, and
  the answer comes back as its own signal — the action body controls the
  reply payload directly without the caller writing a state-projection
  selector.

  `call/3` wires the two halves together:

  * The caller attaches `reply_to: self()` to the
    query signal and casts it to the agent.
  * Once the agent's action runs, it uses `reply/3` (below) to build an
    `%Emit{}` directive whose signal has `subject: query.id` and whose
    target is copied from the query. The runtime delivers it as
    `{:signal, reply_signal}` to the caller's mailbox.
  * `call/3` blocks in a receive that matches on the correlation id and
    returns the reply signal.

  ## Example

      # Client
      {:ok, query} = Aikido.Signal.new("my.agent.ping", %{}, source: "/x")
      {:ok, reply} = Aikido.Signal.Call.call(agent_pid, query)

      # Action handling "my.agent.ping"
      def run(input, _opts, _context) do
        emit = Aikido.Signal.Call.reply(input.context.aikido.signal, "my.agent.ping.reply", %{ok: true})
        Aikido.Types.ActionResult.new(changes: nil, directives: List.wrap(emit))
      end

  ## Why not `Aikido.AgentServer.call/4`?

  `AgentServer.call/4` synchronously dispatches a signal and projects the
  post-pipeline state through a caller-supplied selector. The caller
  decides what crosses the boundary. `Signal.Call.call/3` flips the
  control: the *action* decides what crosses the boundary — useful when
  the answer is an aggregation of server-side internals (running pids,
  logical process lookups, etc.) that the caller can't formulate as a selector
  over `%State{}`. Both still coexist.

  ## Options

  * `:timeout` - ms to wait for a reply. Defaults to
    `Application.get_env(:aikido, :call_timeout_ms, 5_000)`.
  """

  alias Aikido.AgentServer
  alias Aikido.Directives.Emit
  alias Aikido.Signal

  @default_timeout 5_000

  @type option :: {:timeout, timeout()}

  @doc "Returns the default call timeout in ms (app-env overridable)."
  @spec default_timeout() :: timeout()
  def default_timeout do
    Application.get_env(:aikido, :call_timeout_ms, @default_timeout)
  end

  @doc """
  Sends `signal` to `server` and waits for a reply signal whose `subject`
  equals the request's `id`.

  Returns `{:ok, reply_signal}` on success, `{:error, :timeout}` if no
  matching reply arrives within the timeout, `{:error, :noproc}` if the
  target process dies before replying, or any error propagated from
  server resolution (e.g. `{:error, :not_found}` for an unregistered
  name).
  """
  @spec call(AgentServer.server(), Signal.t(), [option]) ::
          {:ok, Signal.t()} | {:error, term()}
  def call(server, %Signal{} = signal, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    query = signal |> Aikido.Directive.materialize_signal() |> attach_reply_destination()

    with {:ok, pid} <- AgentServer.resolve(server) do
      send_query_and_await_reply(pid, query, timeout)
    end
  end

  defp attach_reply_destination(%Signal{reply_to: nil} = signal),
    do: %{signal | reply_to: self()}

  defp attach_reply_destination(signal), do: signal

  defp send_query_and_await_reply(pid, query, timeout) do
    ref = Process.monitor(pid)
    :ok = AgentServer.cast(pid, query)

    try do
      await_reply(query.id, ref, timeout)
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp await_reply(correlation_id, monitor_ref, timeout) do
    receive do
      {:signal, %Signal{subject: ^correlation_id} = reply} ->
        {:ok, reply}

      {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
        {:error, :noproc}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc """
  Builds an `%Emit{}` directive that replies to an input query signal.

  `reply_type` is the type of the reply signal; `data` is its payload.
  The reply's `subject` is set to the input signal's `id`, and the
  reply's destination is copied from the input signal — which is how
  `call/3` finds it back.

  Returns `nil` if the input signal lacks a reply destination (i.e. it was
  not sent by `call/3` and the caller isn't expecting an answer). That
  lets action code be flexible:

      case Aikido.Signal.Call.reply(input.context.aikido.signal, "my.reply", %{value: 42}) do
        nil -> Aikido.Types.ActionResult.new(changes: nil)
        emit -> Aikido.Types.ActionResult.new(changes: nil, directives: [emit])
      end
  """
  @spec reply(Signal.t() | nil, String.t(), map()) :: Emit.t() | nil
  def reply(nil, _type, _data), do: nil
  def reply(%Signal{reply_to: nil}, _type, _data), do: nil

  def reply(%Signal{id: req_id, reply_to: target}, reply_type, data)
      when is_binary(reply_type) and is_map(data) do
    reply_signal =
      %Signal{id: nil, type: reply_type, data: data, source: "/aikido", subject: req_id}

    %Emit{signal: reply_signal, target: target}
  end
end
