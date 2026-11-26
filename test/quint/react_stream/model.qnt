module react_stream {
  type Action = Init | Stream({ current: bool, turn: int, attempt: int, sequence: int }) | Cancel | Complete | Begin | Ready({ current: bool, fresh: bool })
  type Result = Accepted | Rejected(str)
  var generation: int
  var status: str
  var attempt: int
  var sequence: int
  var text: List[str]
  var effects: List[str]
  var iteration: int
  var lastAction: Action
  var lastResult: Result

  action init = all {
    status' = "idle", generation' = 0, attempt' = 0, sequence' = 0, text' = List(), iteration' = 0,
    effects' = List(), lastAction' = Init, lastResult' = Accepted,
  }

  action stream(current: bool, turn: int, incoming: int, seq: int): bool = {
    val accept = status == "running" and current and turn == 1 and incoming >= attempt and
      (if (sequence == 0 or incoming != attempt) seq == 1 else seq == sequence + 1)
    all {
      status' = status, generation' = generation, iteration' = iteration,
      attempt' = if (accept) incoming else attempt,
      sequence' = if (accept) seq else sequence,
      text' = if (accept) (if (incoming > attempt) List("x") else text.append("x")) else text,
      effects' = List(), lastAction' = Stream({ current: current, turn: turn, attempt: incoming, sequence: seq }),
      lastResult' = Accepted,
    }
  }

  action cancel = all {
    status' = if (status == "running" or status == "setup") "failed" else status,
    sequence' = if (status == "running" or status == "setup") 0 else sequence,
    generation' = generation, attempt' = attempt, text' = text, iteration' = iteration,
    effects' = List(), lastAction' = Cancel, lastResult' = Accepted,
  }

  action complete = all {
    generation' = generation,
    status' = if (status == "running") "completed" else status,
    sequence' = if (status == "running") 0 else sequence,
    attempt' = if (status == "running") 0 else attempt,
    text' = if (status == "running") List("d", "o", "n", "e") else text,
    iteration' = if (status == "running") 1 else iteration,
    effects' = List(), lastAction' = Complete, lastResult' = Accepted,
  }

  action begin = all {
    status != "running" and status != "setup",
    status' = "setup", generation' = generation + 1,
    attempt' = 0, sequence' = 0, text' = List(), iteration' = 0,
    effects' = List("PrepareTools"), lastAction' = Begin, lastResult' = Accepted,
  }

  action ready(current: bool, fresh: bool): bool = {
    val accept = status == "setup" and current and fresh
    all {
      status' = if (accept) "running" else status,
      generation' = generation, attempt' = attempt, sequence' = sequence,
      text' = text, iteration' = iteration,
      effects' = if (accept) List("LLMCall") else List(),
      lastAction' = Ready({ current: current, fresh: fresh }), lastResult' = Accepted,
    }
  }

  val receiptLifecycle = status == "running" or sequence == 0

  action step = any {
    nondet current = Set(true, false).oneOf()
    nondet turn = 0.to(2).oneOf()
    nondet incoming = 0.to(1).oneOf()
    nondet seq = 1.to(3).oneOf()
    stream(current, turn, incoming, seq),
    cancel, complete, begin,
    nondet current = Set(true, false).oneOf()
    nondet fresh = Set(true, false).oneOf()
    ready(current, fresh),
  }
}
