# US-AIKIDO-MULTIMODAL-10: Mixed pending input storage

Given pending input includes a text-only message followed by an authored message
with image and file parts.

When native Ash dumps and reloads that input using each declared queue type.

Then message order, authored text, native content parts, media types and bytes
are retained rather than being reduced to display text.

Owning test: `native queue type dumping retains a mixed ordered message list` in
`test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-10`.
