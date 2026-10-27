if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Aikido.Inspector.CodeBlock do
    @moduledoc "Code and data blocks shared by source viewers, inspectors and agent details."
    use Phoenix.Component

    attr :text, :string, required: true
    attr :lexer, :atom, default: Makeup.Lexers.JsonLexer

    def highlighted_code(assigns) do
      lexer = assigns.lexer
      assigns = assign(assigns, :tokens, lexer.lex(assigns.text))

      ~H"""
      <pre class="syntax-highlight"><code><.highlighted_token :for={token <- @tokens} token={token} /></code></pre>
      """
    end

    attr :token, :any, required: true

    defp highlighted_token(%{token: {type, metadata, value}} = assigns) do
      assigns =
        assigns
        |> assign(:text, IO.chardata_to_string([value]))
        |> assign(:token_class, Makeup.Token.Utils.css_class_for_token_type(type))
        |> assign(:group_id, metadata[:group_id])
        |> assign(:selectable, metadata[:selectable] != false)

      ~H"""
      <span class={[@token_class, !@selectable && "unselectable"]} data-group-id={@group_id}>{@text}</span>
      """
    end

    attr :value, :any, required: true
    attr :limit, :any, default: 50
    attr :pretty, :boolean, default: true
    attr :rest, :global

    def inspected_value(assigns) do
      ~H"""
      <pre {@rest}>{inspect(@value, pretty: @pretty, limit: @limit)}</pre>
      """
    end

    attr :text, :string, required: true

    def plain_code(assigns) do
      ~H"""
      <pre>{@text}</pre>
      """
    end
  end
end
