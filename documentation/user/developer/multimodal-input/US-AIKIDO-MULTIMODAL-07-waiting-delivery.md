# US-AIKIDO-MULTIMODAL-07: Delivery while waiting

Given a real agent has answered but is waiting for evidence on a blocking todo.

When its caller delivers authored evidence and native content parts with a
delivery request ID through the generated domain command.

Then the receiving run resumes and the next model request includes the complete
delivery as one ordered user message.

Owning generated test: `deliver resumes a waiting run with all parts in the same user turn`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-07`.
