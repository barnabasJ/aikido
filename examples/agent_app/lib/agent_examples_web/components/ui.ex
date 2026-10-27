defmodule AgentExamplesWeb.Components.UI do
  @moduledoc "Shared panel headings, messages, task rows, tool details and tree navigation."
  use Phoenix.Component
  import Aikido.Inspector.CodeBlock, only: [plain_code: 1, inspected_value: 1]
  import AgentExamplesWeb.Markdown

  attr :level, :integer, values: [2, 3], default: 2
  attr :title_id, :string, default: nil
  slot :title, required: true
  slot :inner_block

  def section_heading(assigns) do
    ~H"""
    <div class="section-heading">
      <h2 :if={@level == 2} id={@title_id}>{render_slot(@title)}</h2>
      <h3 :if={@level == 3} id={@title_id}>{render_slot(@title)}</h3>{render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :label, :string, required: true
  attr :text, :string, required: true
  attr :format, :atom, values: [:markdown, :paragraph], default: :markdown

  def message(assigns) do
    ~H"""
    <article id={@id} class={@class}>
      <span>{@label}</span>
      <.markdown :if={@format == :markdown} text={@text} />
      <p :if={@format == :paragraph}>{@text}</p>
    </article>
    """
  end

  attr :item, :map, required: true
  attr :controls, :boolean, default: false
  attr :show_result, :boolean, default: false
  attr :complete_event, :string, default: "todo_complete"
  attr :block_event, :string, default: "todo_block"
  attr :remove_event, :string, default: "todo_remove"

  def todo_item(assigns) do
    ~H"""
    <article id={"todo-#{@item.id}"}>
      <span>{@item.text} · {@item.status}</span>
      <.inspected_value :if={@show_result} value={@item.result} pretty={false} />
      <button
        :if={@controls}
        class="button secondary"
        phx-click={@complete_event}
        phx-value-id={@item.id}
      >Complete</button>
      <button
        :if={@controls}
        class="button secondary"
        phx-click={@block_event}
        phx-value-id={@item.id}
      >Block</button>
      <button
        :if={@controls}
        class="button secondary"
        phx-click={@remove_event}
        phx-value-id={@item.id}
      >Remove</button>
    </article>
    """
  end

  attr :tool, :map, required: true

  def tool_call(assigns) do
    ~H"""
    <details data-tool-status={@tool.status}>
      <summary>
        {@tool.label}<span>{case @tool.status do
          :pending -> "Pending result"
          :completed -> "Succeeded"
          :failed -> "Failed"
          :unfinished -> "Run ended without result"
        end}</span>
      </summary>
      <small>Tool: {@tool.name}</small><.plain_code text={@tool.input} />
      <details :if={@tool.result}>
        <summary>Tool result</summary><.plain_code text={@tool.result} />
      </details>
    </details>
    """
  end

  attr :event, :string, required: true
  attr :parent, :string, required: true
  attr :root, :string, required: true
  attr :at_root, :boolean, required: true
  attr :tree_id, :string, default: nil
  attr :value_key, :string, default: "node"

  def tree_navigation(assigns) do
    ~H"""
    <div class="sort-navigation">
      <button
        class="button"
        phx-click={@event}
        phx-value-tree={@tree_id}
        {Map.new([{"phx-value-#{@value_key}", @parent}])}
        disabled={@at_root}
      >Up one parent</button>
      <button
        class="button"
        phx-click={@event}
        phx-value-tree={@tree_id}
        {Map.new([{"phx-value-#{@value_key}", @root}])}
        disabled={@at_root}
      >Back to root</button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, default: 1
  attr :disabled, :boolean, default: false
  attr :button_class, :string, default: "button secondary"
  attr :button_text, :string, required: true

  def amount_command(assigns) do
    ~H"""
    <form id={@id} phx-submit={@event} class="inline-form">
      <label>{@label}<input type="number" name="amount" value={@value} /></label>
      <button class={@button_class} disabled={@disabled}>{@button_text}</button>
    </form>
    """
  end

  attr :items, :list, required: true

  def status_legend(assigns) do
    ~H"""
    <p class="sort-legend">
      <span :for={{label, color} <- @items} style={if color, do: "color:var(--#{color})"}>{label}</span>
    </p>
    """
  end

  attr :active, :boolean, default: false
  attr :tag, :atom, values: [:span, :p], default: :span
  slot :inner_block, required: true

  def status_pill(assigns) do
    ~H"""
    <span :if={@tag == :span} class={["status-pill", @active && "on"]}>{render_slot(@inner_block)}</span>
    <p :if={@tag == :p} class={["status-pill", @active && "on"]}>{render_slot(@inner_block)}</p>
    """
  end
end
