if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Aikido.Inspector.Components do
    @moduledoc """
    Compact, read-only signal history and expandable state for LiveView applications.

    Available when the application installs `:phoenix_live_view`. The core observer
    and `Aikido.Inspector.History` do not depend on LiveView.

    Assign a history from `Aikido.Inspector.History.new/0` to `:inspection`, mount
    `{Aikido.Inspector.Components, :default}`, and render:

        <Aikido.Inspector.Components.inspector
          history={@inspection}
          selected={@inspection_selected}
          view={@inspection_view}
          format={@inspection_format}
          filter={@inspection_filter}
        />

    The mount hook handles selection, filtering and view changes. A custom
    `{:history, reader}` mount option accepts a function of socket assigns when
    the application stores history elsewhere. Pinned entries remain selected
    when new events arrive, including after they leave the bounded history.

    Serve `priv/static` from the `:aikido` application with `Plug.Static`. Include
    `inspector/inspector.css` and import the `AgentIdentity` hook exported by
    `inspector/inspector.js` into the application's LiveSocket hooks. The supplied
    stylesheet provides the dark palette and compact, scrollable panes.

    Render one inspector per LiveView. State is historical and read-only; effects
    cannot be replayed. Project sensitive values with `Aikido.Inspector.History`
    before sending them to the browser.
    """
    use Phoenix.Component
    import Aikido.Inspector.CodeBlock, only: [highlighted_code: 1]

    import Phoenix.LiveView

    def on_mount(:default, params, session, socket),
      do: on_mount({:history, &Map.get(&1, :inspection)}, params, session, socket)

    def on_mount({:history, reader}, _params, _session, socket) when is_function(reader, 1) do
      socket =
        socket
        |> assign(:inspection_history_reader, reader)
        |> assign_new(:inspection_selected, fn -> nil end)
        |> assign_new(:inspection_view, fn -> "diff" end)
        |> assign_new(:inspection_format, fn -> "tree" end)
        |> assign_new(:inspection_filter, fn -> "" end)
        |> attach_hook(:inspector_commands, :handle_event, &handle_event/3)

      {:cont, socket}
    end

    defp handle_event("inspect_event", params, socket),
      do: {:halt, pin_inspected_event(socket, params)}

    defp handle_event("inspection_live", _, socket),
      do: {:halt, assign(socket, inspection_selected: nil)}

    defp handle_event("inspection_view", %{"view" => view} = params, socket)
         when view in ["diff", "before", "after", "signal", "actions", "directives"] do
      {:halt, socket |> pin_inspected_event(params) |> assign(inspection_view: view)}
    end

    defp handle_event("inspection_format", %{"format" => format} = params, socket)
         when format in ["tree", "raw"],
         do: {:halt, socket |> pin_inspected_event(params) |> assign(inspection_format: format)}

    defp handle_event("inspection_filter", %{"filter" => filter}, socket),
      do: {:halt, assign(socket, inspection_filter: filter, inspection_selected: nil)}

    defp handle_event(_, _, socket), do: {:cont, socket}

    defp pin_inspected_event(socket, %{"sequence" => sequence}) do
      history = socket.assigns.inspection_history_reader.(socket.assigns)
      entries = if history, do: history.entries, else: []
      pinned = socket.assigns.inspection_selected

      case Enum.find(entries, &(to_string(&1.sequence) == sequence)) do
        nil ->
          socket

        entry ->
          assign(socket,
            inspection_selected:
              if(pinned && pinned.sequence == entry.sequence, do: pinned, else: entry)
          )
      end
    end

    defp pin_inspected_event(socket, _), do: socket

    attr :history, :map, default: nil
    attr :selected, :any, default: nil
    attr :view, :string, default: "diff"
    attr :format, :string, default: "tree"
    attr :filter, :string, default: ""

    def inspector(assigns) do
      entries = if assigns.history, do: assigns.history.entries, else: []
      terms = Aikido.Inspector.History.Filter.parse(assigns.filter)

      entries =
        Enum.filter(entries, &Aikido.Inspector.History.Filter.matches?(&1, terms))

      selected =
        case assigns.selected do
          %{sequence: _} = pinned -> pinned
          sequence -> Enum.find(entries, &(&1.sequence == sequence)) || List.first(entries)
        end

      content = if selected, do: event_content(selected, assigns.view)

      assigns =
        assign(assigns,
          entries: entries,
          entry: selected,
          content: content,
          highlighted: if(assigns.format == "raw", do: Jason.encode!(content, pretty: true))
        )

      ~H"""
      <section :if={@history} class="aikido-inspector" id="aikido-inspector" aria-label="Aikido inspector">
        <header class="inspector-toolbar">
          <h2>Aikido inspector</h2>
          <span>{length(@entries)} / 100 signals</span>
          <button
            type="button"
            class="inspector-live"
            phx-click="inspection_live"
            aria-pressed={to_string(is_nil(@selected))}
            title="Follow the newest signal"
          >Live</button>
          <span class="inspector-readonly" title="Historical inspection only. No effects are replayed.">Read-only</span>
        </header>
        <div class="inspector-grid">
          <div class="inspector-history">
            <form phx-change="inspection_filter" id="inspector-filter">
              <input
                aria-label="Filter by agent ID or signal"
                placeholder="Filter signals or agents… e.g. -lifecycle"
                title="Space-separated terms; prefix a term with - to exclude it"
                name="filter"
                value={@filter}
                phx-debounce="200"
              />
            </form>
            <div class="inspector-timeline" aria-label="Recorded signals">
              <.event_row :for={event <- @entries} event={event} selected={@entry && @entry.sequence} />
              <p :if={@entries == []} class="inspector-empty">No matching signals.</p>
            </div>
          </div>
          <div class="inspector-event" id="inspector-event">
            <.detail_tabs view={@view} sequence={@entry && @entry.sequence} />
            <div class="inspector-subtoolbar">
              <.format_tabs format={@format} sequence={@entry && @entry.sequence} />
              <span :if={@entry} title={@entry.agent_id}>{if @entry.agent == "",
                do: "Root",
                else: @entry.agent}</span>
            </div>
            <div
              class="inspector-content"
              id="inspector-content"
              phx-click="inspect_event"
              phx-value-sequence={@entry && @entry.sequence}
            >
              <p :if={!@entry} class="inspector-empty">
                Send a command to inspect its state transition.
              </p>
              <.signal_failure :if={@entry && @entry.execution.error} entry={@entry} />
              <p :if={@entry && is_nil(@entry.after)} class="inspector-empty">
                Start a fresh run to capture detailed state.
              </p>
              <p
                :if={
                  @format == "tree" && is_map(@content) && @content["truncated"] == true &&
                    is_binary(@content["preview"])
                }
                class="inspector-empty"
              >
                This older snapshot was stored as a text preview. New signals preserve the expandable tree.
              </p>
              <p :if={@entry && @view == "diff" && is_nil(@entry.before)} class="inspector-empty">
                No earlier snapshot; this event establishes the baseline.
              </p>
              <p :if={@entry && @view == "actions"} class="inspector-empty">
                Native Ash action spans in invocation order. Durations include nested work;
                an ended span does not imply success. Mount paths come from the DSL.
                Showing up to 100 of {@entry.execution[:action_count] || 0} observed actions.
              </p>
              <p
                :if={@entry && @view == "directives" && (@entry.execution[:directive_count] || 0) > 30}
                class="inspector-empty"
              >
                Showing the first 30 directives.
              </p>
              <div
                :if={@entry}
                id={"inspector-value-#{@entry.sequence}-#{@view}-#{@format}"}
                phx-update="ignore"
              >
                <%= cond do %>
                  <% @format == "raw" -> %>
                    <.highlighted_code text={@highlighted} />
                  <% @view == "diff" -> %>
                    <.state_diff changes={@content} />
                  <% true -> %>
                    <.value_tree label={@view} value={@content} />
                <% end %>
              </div>
            </div>
          </div>
        </div>
        <footer class="inspector-footer">
          <span :if={@entry} title={@entry.agent_id}>#{@entry.sequence} · {@entry.agent_id}</span>
          <span title="Conversation bodies and credential fields are redacted. Large values are truncated.">Redacted · UTC</span>
        </footer>
      </section>
      """
    end

    attr :entry, :map, required: true

    def signal_failure(assigns) do
      title =
        case assigns.entry.execution.error do
          %{"class" => class} when class in ["invalid", "forbidden"] -> "Signal rejected"
          _ -> "Signal processing failed"
        end

      assigns = assign(assigns, :title, title)

      assigns =
        assign(
          assigns,
          :explanation,
          assigns.entry.execution[:error_message] ||
            Aikido.Inspector.History.error_message(assigns.entry.execution.error)
        )

      ~H"""
      <section class="inspector-failure" role="alert">
        <strong>{@title}</strong>
        <p class="inspector-failure-message">{@explanation}</p>
        <p :if={@entry.after} class="inspector-failure-status">
          The agent reported its state after this error. This event does not report a process exit.
        </p>
        <p class="inspector-failure-status">
          {cond do
            is_nil(@entry.before) -> "No earlier state snapshot recorded."
            @entry.before == @entry.after -> "State unchanged."
            true -> "State changed; compare the before and after snapshots."
          end}
          {@entry.execution[:directive_count] || length(@entry.execution.directives)} directives returned.
        </p>
        <nav class="inspector-failure-links" aria-label="Inspect failed signal">
          <button
            :for={
              {view, label} <- [
                {"signal", "Input signal"},
                {"before", "Before state"},
                {"after", "After state"}
              ]
            }
            type="button"
            phx-click="inspection_view"
            phx-value-view={view}
            phx-value-sequence={@entry.sequence}
          >
            {label}
          </button>
        </nav>
        <details class="inspector-failure-details">
          <summary>Raw error details</summary>
          <.value_tree label="error" value={@entry.execution.error} />
        </details>
      </section>
      """
    end

    attr :label, :string, required: true
    attr :value, :any, required: true
    attr :depth, :integer, default: 0

    def value_tree(assigns) do
      assigns = assign(assigns, :children, children(assigns.value))

      ~H"""
      <details :if={@children != []} class="inspector-value" open={@depth == 0}>
        <summary>
          <span class="inspector-key">{@label}</span><span class="inspector-punctuation">: {preview(
            @value
          )}</span>
        </summary>
        <div class="inspector-children">
          <.value_tree
            :for={{key, value} <- @children}
            label={to_string(key)}
            value={value}
            depth={@depth + 1}
          />
        </div>
      </details>
      <div :if={@children == []} class="inspector-leaf">
        <span class="inspector-key">{@label}</span><span class="inspector-punctuation">: </span><span class={
          value_class(@value)
        }>{Jason.encode!(@value)}</span>
      </div>
      """
    end

    defp children(value) when is_map(value), do: Enum.sort_by(value, &elem(&1, 0))

    defp children(value) when is_list(value),
      do: value |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v} end)

    defp children(_), do: []

    defp preview(%{type: type, fields: _}) when is_binary(type), do: type
    defp preview(value) when is_map(value), do: "{#{map_size(value)} keys}"
    defp preview(value) when is_list(value), do: "[#{length(value)} items]"
    defp preview(value), do: value |> Jason.encode!() |> String.slice(0, 120)

    defp value_class(value) when is_binary(value), do: "inspector-string"
    defp value_class(value) when is_number(value), do: "inspector-number"
    defp value_class(_), do: "inspector-literal"

    defp agent_label(%{agent: ""}), do: "Root"

    defp agent_label(event), do: event.agent |> String.split(" / ") |> List.last()

    defp process_color(event) do
      identity = Map.get(event, :agent_pid) || event.agent_id
      <<red, green, blue>> = <<:erlang.phash2(identity, 16_777_216)::24>>

      # Keep hashed channels bright enough to read against the navy surface.
      "#" <> Base.encode16(<<128 + div(red, 2), 128 + div(green, 2), 128 + div(blue, 2)>>)
    end

    defp event_content(entry, "diff"), do: entry.changes
    defp event_content(entry, "before"), do: entry.before
    defp event_content(entry, "after"), do: entry.after
    defp event_content(entry, "signal"), do: entry.execution.signal
    defp event_content(entry, "directives"), do: entry.execution.directives
    defp event_content(entry, "actions"), do: entry.execution[:actions] || []

    attr :event, :map, required: true
    attr :selected, :any, default: nil

    def event_row(assigns) do
      ~H"""
      <div class={
        if @event.execution.error,
          do: "inspector-row inspector-row-error",
          else: "inspector-row"
      }>
        <button
          type="button"
          phx-click="inspect_event"
          phx-value-sequence={@event.sequence}
          aria-pressed={to_string(@event.sequence == @selected)}
          title={"#{@event.execution.signal.type}\n#{@event.agent_id}\n#{@event.time} · #{length(@event.changes)} changes · #{@event.execution[:directive_count] || length(@event.execution.directives)} directives"}
        >
          <span class="inspector-sequence">{@event.sequence}</span>
          <span class="inspector-signal">{@event.execution.signal.type}</span>
        </button>
        <.event_identity event={@event} />
      </div>
      """
    end

    attr :event, :map, required: true

    def event_identity(assigns) do
      ~H"""
      <div
        class="inspector-identity"
        id={"inspector-identity-#{@event.sequence}"}
        phx-hook="AgentIdentity"
      >
        <button
          type="button"
          class="inspector-agent"
          aria-label={"Agent ID for #{Map.get(@event, :agent_pid) || agent_label(@event)}"}
          title={@event.agent_id}
          style={"color: #{process_color(@event)}"}
        >
          {Map.get(@event, :agent_pid) || agent_label(@event)}
        </button>
        <div class="inspector-id-popup" role="group" aria-label="Copy agent identity">
          <button type="button" data-copy-agent-id={@event.agent_id} title="Copy agent ID">
            <code>{@event.agent_id}</code><span class="inspector-copy-label">Copy ID</span>
          </button>
        </div>
      </div>
      """
    end

    attr :view, :string, required: true
    attr :sequence, :any, default: nil

    def detail_tabs(assigns) do
      ~H"""
      <nav class="inspector-tabs" aria-label="Event details">
        <button
          :for={
            {tab, label} <- [
              {"signal", "Signal"},
              {"after", "State"},
              {"diff", "Diff"},
              {"before", "Before"},
              {"actions", "Actions"},
              {"directives", "Directives"}
            ]
          }
          type="button"
          phx-click="inspection_view"
          phx-value-view={tab}
          phx-value-sequence={@sequence}
          aria-pressed={to_string(@view == tab)}
        >{label}</button>
      </nav>
      """
    end

    attr :format, :string, required: true
    attr :sequence, :any, default: nil

    def format_tabs(assigns) do
      ~H"""
      <div class="inspector-formats" role="group" aria-label="Value format">
        <button
          :for={format <- ~w(tree raw)}
          type="button"
          phx-click="inspection_format"
          phx-value-format={format}
          phx-value-sequence={@sequence}
          aria-pressed={to_string(@format == format)}
        >{String.capitalize(format)}</button>
      </div>
      """
    end

    attr :changes, :list, required: true

    def state_diff(assigns) do
      ~H"""
      <p :if={@changes == []} class="inspector-empty">No state changes.</p>
      <details :for={change <- @changes} class="inspector-change">
        <summary>
          <span class="inspector-key">{if change.path == "",
            do: "state",
            else: change.path}</span>
          <del>{preview(change.before)}</del><span class="inspector-arrow">→</span><ins>{preview(
            change.after
          )}</ins>
        </summary>
        <div class="inspector-change-values">
          <.value_tree label="before" value={change.before} />
          <.value_tree label="after" value={change.after} />
        </div>
      </details>
      """
    end
  end
end
