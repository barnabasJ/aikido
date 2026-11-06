# Multimodal user input

Keep the authored prompt as a string and pass additional content through
`content_parts`. Aikido puts the prompt first, followed by the supplied parts,
in a single native ReqLLM user message. Existing string-only call signatures
remain supported.

Authored query/text preserves its leading and trailing whitespace, including
newlines. Native Ash string constraints still reject empty and whitespace-only
authored input; attachment parts do not make a blank required prompt valid.

```elixir
alias ReqLLM.Message.ContentPart

parts = [
  ContentPart.image(authorized_image_bytes, "image/png"),
  ContentPart.file(authorized_file_bytes, "notes.txt", "text/plain")
]

MyApp.Agents.assistant_ask(
  reference,
  %{query: "Compare these attachments", content_parts: parts},
  scope: caller_scope
)
```

The generated command and the `ai.react.ask`, `ai.react.message`, and
`ai.react.deliver` signals accept an optional list of
`ReqLLM.Message.ContentPart` structs. Native Ash argument constraints check the
struct contract. Use ReqLLM's constructors to create parts; arbitrary maps are
not an alternative input format.

The convenience API accepts the same option:

```elixir
Aikido.AI.ask_sync(reference.pid, "Compare these attachments",
  content_parts: parts,
  scope: caller_scope
)

Aikido.AI.queue_message(reference.pid, "Consider this too",
  content_parts: parts,
  scope: caller_scope
)
```

For deliveries, supply `text`, `content_parts`, and the normal `request_id`.
Delivery deduplication still uses that request ID. Messages arriving during
model work retain their ordering until the next safe model boundary; a waiting
run resumes with the complete message. Parts do not grant authority or replace
the actor, tenant, or context carried by the signal envelope.

The application owns attachment authorization, loading bytes or generating
usable URLs, and selecting a model that supports the content. Aikido does not
load application Blobs. Provider file IDs and URLs have provider-specific
availability and expiry rules. Accepting a native content part does not prove
that every provider supports it.

Conversation history retains native ReqLLM messages and their content parts.
Durable restart restores saved history and queued input; it does not resume an
interrupted model request. Application projections of that history must retain
the desired attachment representation instead of extracting only text. Aikido
does not automatically add application SQL transcript entries.

The content-parts arguments and both input queues carry native Ash sensitive
metadata. Ash resource `Inspect` output omits the queues, and the existing
Aikido Inspector history projection redacts them. Sensitivity is a diagnostic
annotation, not an authorization policy: an authorized inspect command still
returns the actual selected state. Use the resource-aware Inspector projection
for diagnostic maps; converting state to a plain map and inspecting it directly
does not retain resource metadata.

Pending UTF-8 text from older typed snapshots remains supported. The two input
queues now use native Ash term storage, with a load-only compatibility branch
for old raw text. Non-UTF-8 legacy binaries beginning with byte 131 are outside
that text compatibility contract: they reach the native term decoder and
invalid terms fail instead of falling back to text. Arbitrary old binaries that
are themselves valid external terms cannot be distinguished from term storage.
Keep this compatibility branch while old snapshots or restorable backups remain
supported.
