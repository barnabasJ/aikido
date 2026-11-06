# US-AIKIDO-MULTIMODAL-05: Synchronous input

Given a real agent is ready to accept a user request.

When the caller uses `Aikido.AI.ask_sync` with authored text and native image
and file parts, and the external model replies.

Then the model receives one complete user turn in the supplied order and the
caller receives its final answer through the normal completion subscription.

Owning test: `ask_sync forwards content parts without replacing native history`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-05`.
