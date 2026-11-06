# US-AIKIDO-MULTIMODAL-06: Message while waiting

Given a real agent has answered but is waiting for evidence on a blocking todo.

When its caller sends a multipart message through `Aikido.AI.queue_message`.

Then the existing run resumes and the next model request includes authored
evidence text followed by all supplied parts in one user message.

Owning generated test: `message resumes a waiting run with all parts in the same user turn`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-06`.
