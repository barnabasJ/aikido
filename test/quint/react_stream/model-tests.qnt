module tests {
  import react_stream.* from "./model"
  run orderedAndDuplicateTest = init.then(begin).then(ready(true, true)).then(stream(true, 1, 0, 1)).then(stream(true, 1, 0, 1)).then(stream(true, 1, 0, 2)).expect(text == List("x", "x") and sequence == 2)
  run retryAndStaleTest = init.then(begin).then(ready(true, true)).then(stream(true, 1, 0, 1)).then(stream(true, 1, 1, 1)).then(stream(true, 1, 0, 2)).expect(text == List("x") and attempt == 1)
  run cancelLateBatchTest = init.then(begin).then(ready(true, true)).then(stream(true, 1, 0, 1)).then(cancel).then(stream(true, 1, 0, 2)).expect(status == "failed" and text == List("x") and sequence == 0)
  run completeRestartTest = init.then(begin).then(ready(true, true)).then(complete).then(begin).then(ready(true, true)).then(stream(false, 1, 0, 1)).then(stream(true, 2, 0, 1)).expect(status == "running" and text == List() and sequence == 0)
  run staleReadinessTest = init.then(begin).then(ready(false, true)).then(ready(true, false)).expect(status == "setup" and effects == List())
}

