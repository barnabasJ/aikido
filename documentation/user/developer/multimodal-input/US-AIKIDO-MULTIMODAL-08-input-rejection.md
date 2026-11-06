# US-AIKIDO-MULTIMODAL-08: Reject untyped content

Given a real agent is idle and accepts native ReqLLM content-part structs.

When a caller submits a plain map as a content part through generated Ask.

Then native Ash argument casting rejects the request, the agent remains idle,
and no model request starts.

Owning test: `native argument casting rejects untyped content maps` in
`test/aikido/ai_react/multimodal_user_turn_test.exs`, tagged
`US-AIKIDO-MULTIMODAL-08`.
