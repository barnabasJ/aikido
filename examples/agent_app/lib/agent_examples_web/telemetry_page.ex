defmodule AgentExamplesWeb.TelemetryPage do
  @moduledoc "System-wide agent and provider diagnostics retained from application startup."
  use Phoenix.LiveDashboard.PageBuilder, refresher?: false
  alias AgentExamples.Telemetry.SystemSnapshot
  import AgentExamplesWeb.Components.TelemetryChart, only: [chart: 1]

  @impl true
  def menu_link(_, _), do: {:ok, "Aikido"}

  @impl true
  def mount(_, _, socket) do
    socket = assign(socket, :overview, SystemSnapshot.read())
    if Phoenix.LiveView.connected?(socket), do: schedule_refresh()
    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_aikido, socket) do
    socket = assign(socket, :overview, SystemSnapshot.read())
    schedule_refresh()
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp schedule_refresh, do: Process.send_after(self(), :refresh_aikido, 1_000)

  @impl true
  def render(assigns) do
    ~H"""
    <section id="aikido-system-overview">
      <h2>Aikido system overview</h2>
      <p id="aikido-refresh-status">Updates every second while this page is connected.</p>
      <p>
        Totals since {Calendar.strftime(@overview.started_at, "%Y-%m-%d %H:%M:%S UTC")}. Retained while this application is running, including before you open the dashboard.
      </p>
      <p :if={@overview.runtime.error} class="alert alert-danger">{@overview.runtime.error}</p>
      <div class="row">
        <.metric
          title="Local agents"
          value={number(@overview.runtime.local_agents)}
          note="Actual processes under the native supervisor"
        />
        <.metric
          title="Registered agents"
          value={number(@overview.runtime.registered_agents)}
          note="Cluster membership; can differ during activation or shutdown"
        />
        <.metric
          title="I/O tasks"
          value={number(@overview.runtime.io_tasks)}
          note="Supervised asynchronous work"
        />
        <.metric
          title="Active LLM requests"
          value={@overview.active_count}
          note="Started requests awaiting a native terminal event"
        />
        <.metric
          title="Call/cast dispatches"
          value={@overview.totals.signals_sent}
          note="Dispatch attempts, not delivery acknowledgements"
        />
        <.metric
          title="Signals processed"
          value={@overview.totals.signals_processed}
          note={"#{@overview.totals.signal_errors} reducer or processing exceptions"}
        />
        <.metric
          title="Directives dispatched"
          value={@overview.totals.directives}
          note={"#{@overview.totals.directive_errors} dispatch exceptions"}
        />
        <.metric
          title="LLM requests finished"
          value={@overview.totals.llm_finished}
          note={"#{@overview.totals.llm_http_errors} HTTP errors · #{@overview.totals.llm_exceptions} exceptions · #{@overview.totals.llm_retries} retries"}
        />
      </div>
      <div class="row">
        <.metric
          title="Input tokens"
          value={number(@overview.usage[:input_tokens])}
          note="Reported provider usage"
        />
        <.metric
          title="Output tokens"
          value={number(@overview.usage[:output_tokens])}
          note="Reported provider usage"
        />
        <.metric
          title="Reasoning tokens"
          value={number(@overview.usage[:reasoning_tokens])}
          note="Reported provider usage"
        />
        <.metric
          title="Reported cost (USD)"
          value={cost(@overview.usage[:total_cost])}
          note={"#{@overview.missing_cost} finished requests without pricing; unavailable is not zero"}
        />
      </div>
      <div class="row" id="aikido-signal-charts">
        <.chart
          id="signal-throughput-chart"
          title="Signal processing throughput"
          unit="signals / second"
          points={@overview.signal_series}
          series={[{:throughput, "Processed", "#2563eb"}]}
          note="Completed signals per elapsed second. Last 120 samples; collected even while the dashboard is closed."
        />
        <.chart
          id="signal-duration-chart"
          title="Signal processing duration"
          unit="milliseconds"
          points={@overview.signal_series}
          series={[
            {:median_ms, "Median (upper bound)", "#0f766e"},
            {:p95_ms, "p95 (upper bound)", "#c2410c"}
          ]}
          note="Approximate per-interval quantiles from fixed duration buckets, up to 60 seconds. Gaps mean no durations or values above that bound. Measures reducer/middleware time before directive execution, not task completion or mailbox wait."
        />
      </div>
      <h3>What agents are doing</h3>
      <p>
        PID-sorted sample of up to {@overview.sample_limit} local processes. Reads have a 100 ms deadline; unavailable rows may be busy or stopping. No prompts, answers or credentials are collected.
      </p>
      <div class="table-responsive">
        <table class="table table-striped" id="aikido-agent-work">
          <thead>
            <tr>
              <th>PID / agent ID</th><th>Resource</th><th>Current state</th><th>Model turn</th><th>
                Pending tools
              </th><th>Delegated tasks</th><th>Mailbox</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={agent <- @overview.runtime.agents}>
              <td>
                <button
                  class="btn btn-link p-0"
                  phx-click="show_info"
                  phx-value-info={encode_pid(agent.pid)}
                >{inspect(agent.pid)}</button><br /><code title={agent.parent}>{agent.id}</code>
              </td>
              <td>{agent.resource && inspect(agent.resource)}</td><td>{agent.status}</td><td>
                {number(agent.iteration)}
              </td>
              <td>{Enum.join(agent.tools, ", ")}</td><td>{number(agent.tasks)}</td><td>
                {number(agent.mailbox)}
              </td>
            </tr>
            <tr :if={@overview.runtime.agents == []}>
              <td colspan="7">No local agent rows available.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <h3>Provider requests</h3>
      <p>
        Up to 50 active requests and the latest 50 terminal observations. An emitter stopping without a terminal event is shown separately from a provider exception.
      </p>
      <div class="table-responsive">
        <table class="table table-striped" id="aikido-provider-requests">
          <thead>
            <tr>
              <th>Request</th><th>Provider / model</th><th>Outcome</th><th>Elapsed / duration</th><th>
                HTTP
              </th><th>Input / output tokens</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={request <- @overview.active ++ @overview.recent}>
              <td>
                <code>{request.request_id}</code><br /><button
                  class="btn btn-link p-0"
                  phx-click="show_info"
                  phx-value-info={encode_pid(request.pid)}
                >{inspect(request.pid)}</button>
              </td><td>{request[:provider]} / {request[:model]}</td>
              <td>
                {request[:outcome] || :active}
                <small :if={request[:finish_reason]} class="d-block text-muted">
                  Finish: {request.finish_reason}
                </small>
              </td><td>
                {milliseconds(request[:elapsed_ms] || request.duration_ms)}
              </td>
              <td>{request[:http_status]}</td><td>
                {number(request.usage.input_tokens)} / {number(request.usage.output_tokens)}
              </td>
            </tr>
            <tr :if={@overview.active == [] and @overview.recent == []}>
              <td colspan="6">No provider requests observed since startup.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p>
        BEAM: {@overview.beam_processes} processes · {Float.round(
          @overview.beam_memory / 1_048_576,
          1
        )} MiB · run queue {@overview.run_queue}.
      </p>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:value, :any, required: true)
  attr(:note, :string, required: true)

  defp metric(assigns) do
    ~H"""
    <div class="col-sm-6 col-lg-3 mb-3">
      <div class="card h-100">
        <div class="card-body">
          <h3 class="h6">{@title}</h3><strong class="h3">{@value}</strong><p class="small mt-2 mb-0">
            {@note}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp number(nil), do: "Not reported"
  defp number(value), do: value
  defp cost(nil), do: "Unavailable"
  defp cost(value), do: "$" <> :erlang.float_to_binary(value / 1, decimals: 6)
  defp milliseconds(nil), do: "Not reported"
  defp milliseconds(value), do: "#{Float.round(value / 1, 1)} ms"
end
