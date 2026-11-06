# US-AIKIDO-MULTIMODAL-15: Blank authored input

Given a real idle agent accepts multipart input and preserves nonblank authored
text exactly, including leading whitespace and trailing newlines.

When a caller sends empty or whitespace-only authored text through generated
Ask, Message or Deliver, or the Ask and QueueMessage convenience APIs.

Then native Ash rejects the required blank value even when parts are supplied,
no run starts, and no pending input or delivery ID is accepted.

Owning test: `blank authored text stays invalid through generated and convenience input`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-15`.
