# US-AIKIDO-MULTIMODAL-14: Both queue projections

Given native Ash creation populates both opening and queued input with multipart
content in the real AI slice resource.

When diagnostics receive that struct or a map with its owning resource context.

Then the existing Inspector projection hides both fields and native struct
Inspect omits their values, while the source input remains unchanged.

Owning test: `the existing diagnostic projection redacts populated opening and queued fields`
in `test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-14`.
