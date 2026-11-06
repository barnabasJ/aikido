# US-AIKIDO-MULTIMODAL-01: One user turn

As an application developer, I want to submit an authored prompt and native
ReqLLM content parts without replacing conversation history.

Given a real agent started through its generated domain action.

When I call generated `ask` with a string prompt and
optional native image and file parts.

Then the model boundary receives exactly one user message whose first part is
the prompt and whose remaining parts retain their supplied order and values.
The native conversation retains the same authored leading whitespace and
trailing newline exactly once; assertions do not trim either representation.
Owning test: `generated ask submits text and ordered native content in one user turn`,
tagged `US-AIKIDO-MULTIMODAL-01` in
`test/aikido/ai_react/multimodal_user_turn_test.exs`.
