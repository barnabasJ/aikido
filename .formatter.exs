spark_locals_without_parens = [
  activation: 1,
  agent: 2,
  agent: 3,
  allow_nil?: 1,
  always_select?: 1,
  attribute: 2,
  attribute: 3,
  client: 1,
  constraints: 1,
  create_timestamp: 1,
  create_timestamp: 2,
  data: 1,
  default: 1,
  depends_on: 1,
  description: 1,
  field: 2,
  field: 3,
  filterable?: 1,
  generated?: 1,
  hooks: 1,
  inherit: 1,
  initial_state: 1,
  instance: 1,
  integer_primary_key: 1,
  integer_primary_key: 2,
  job_id: 1,
  llm_opts: 1,
  match: 1,
  match_other_defaults?: 1,
  max_iterations: 1,
  max_members: 1,
  member: 2,
  member: 3,
  middleware: 1,
  model: 1,
  name: 1,
  operation_timeout: 1,
  options: 1,
  otp_app: 1,
  owner: 1,
  path: 1,
  persistence: 1,
  primary_key?: 1,
  priority: 1,
  public?: 1,
  route: 2,
  route: 3,
  schedule: 2,
  schedule: 3,
  select_by_default?: 1,
  sensitive?: 1,
  signal: 1,
  slice: 2,
  slice: 3,
  sortable?: 1,
  source: 1,
  system_prompt: 1,
  timezone: 1,
  tool_options: 1,
  topology: 1,
  type: 1,
  tz: 1,
  update_default: 1,
  update_timestamp: 1,
  update_timestamp: 2,
  uuid_primary_key: 1,
  uuid_primary_key: 2,
  uuid_v7_primary_key: 1,
  uuid_v7_primary_key: 2,
  worker: 2,
  worker: 3,
  writable?: 1
]

# Keep root formatting consistent with optional DSLs used by example apps.
# Read only their generated arities; core does not load their dependencies.
example_locals_without_parens =
  __DIR__
  |> Path.join("examples/*/.formatter.exs")
  |> Path.wildcard(match_dot: true)
  |> Enum.flat_map(fn path ->
    {options, _} = Code.eval_file(path)
    Keyword.get(options, :locals_without_parens, [])
  end)

# Used by "mix format"
[
  import_deps: [:ash, :spark],
  plugins: [Spark.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{bench,config,lib,test}/**/*.{ex,exs}",
    "examples/*/{mix,.formatter}.exs",
    "examples/*/{config,lib,test}/**/*.{ex,exs}"
  ],
  locals_without_parens: Enum.uniq(spark_locals_without_parens ++ example_locals_without_parens),
  export: [locals_without_parens: spark_locals_without_parens]
]
