## `withEachState`: N independent records, one request each, requests concurrent.
##
## The stub transport stands in for the network, so these assert on what reached
## the wire, in what shape, and on what happens when one record's request fails.

import std/[json, os, strutils, times, asyncdispatch, asynchttpserver]
import reckonim

delEnv("RECKONIM_RECORD")
delEnv("RECKONIM_REPLAY")

type Ticket = object
  id: string
  message: string

let tickets = @[
  Ticket(id: "A", message: "Payouts have been failing for three days. Cancel us."),
  Ticket(id: "B", message: "How do I rotate an API key? No rush."),
  Ticket(id: "C", message: "The invoice is wrong again.")]

var requests: seq[JsonNode]

proc answerAll(p: JsonNode, noul: float): JsonNode =
  var res = newJObject()
  for qid, q in p["questions"]:
    res[qid] = %*{"type": "noul", "noul": noul}
  %*{"model": "jev-1.13.0", "answers": res,
     "usage": {"input_tokens": 100, "output_tokens": 10}}

proc install(transport: Transport) =
  requests = @[]
  globalClient = newClient(apiKey = "x", transport = transport)

proc stateOf(req: JsonNode): string = req["state"]["id"].getStr

# ---------------------------------------------------------------- one per record

block one_request_per_record_never_packed:
  install(proc (p: JsonNode): JsonNode =
    requests.add p
    answerAll(p, 0.94))

  var seen: seq[string]
  withEachState t in tickets:
    if t.message.feels "Is this time-sensitive?":
      seen.add t.id

  doAssert requests.len == 3                  # one request per record
  doAssert seen == @["A", "B", "C"]           # bodies ran in order, on this thread
  for req in requests:
    # The state is the record itself. Records are never packed into a shared
    # array state, so no question ever indexes a neighbour.
    doAssert req["state"].kind == JObject
    doAssert req["questions"].len == 1
  doAssert @[stateOf(requests[0]), stateOf(requests[1]), stateOf(requests[2])] ==
           @["A", "B", "C"]

block every_judgment_in_the_block_rides_its_own_record:
  install(proc (p: JsonNode): JsonNode =
    requests.add p
    answerAll(p, 0.94))

  withEachState t in tickets:
    if t.message.feels "Is this time-sensitive?":
      if t.message.feels "Is the sender angry?":      # speculative, still sent
        discard
    discard t.feels "Is this ticket actionable?"

  doAssert requests.len == 3
  for req in requests:
    doAssert req["questions"].len == 3

block identical_judgments_still_dedup_within_a_record:
  install(proc (p: JsonNode): JsonNode =
    requests.add p
    answerAll(p, 0.94))

  withEachState t in tickets:
    discard t.message.feels "Is this time-sensitive?"
    discard t.message.feels "Is this time-sensitive?"

  doAssert requests[0]["questions"].len == 1

block empty_collection_sends_nothing:
  install(proc (p: JsonNode): JsonNode =
    requests.add p
    answerAll(p, 0.94))

  var ran = 0
  let none: seq[Ticket] = @[]
  withEachState t in none:
    if t.message.feels "Is this time-sensitive?": inc ran

  doAssert requests.len == 0
  doAssert ran == 0

# ---------------------------------------------------------------- failure

block a_failed_record_parks_and_raises_only_on_read:
  # A 400 is terminal: the request itself is wrong, so it is never rescheduled.
  install(proc (p: JsonNode): JsonNode =
    requests.add p
    if "rotate an API key" in $p["state"]:
      var e = newException(JevServiceError, "HTTP 400: malformed question")
      e.status = 400
      raise e
    answerAll(p, 0.94))

  var reached: seq[string]
  var raised = ""
  withEachState t in tickets:
    let urgent = t.message.feels "Is this time-sensitive?"
    reached.add t.id                        # the body runs for every record
    if t.id == "B":
      try:
        discard urgent.probability
        doAssert false, "reading a parked judgment must raise"
      except JevServiceError as e:
        raised = e.msg
    else:
      doAssert urgent.probability == 0.94   # siblings are unaffected

  doAssert reached == @["A", "B", "C"]      # one bad record did not kill the run
  doAssert "400" in raised                  # the original error, not a wrapper

block a_retryable_failure_is_rescheduled_once:
  # Transport errors are collective as often as not, so the survivors of the
  # wave get one more attempt on their own once it has drained.
  var attempts = 0
  install(proc (p: JsonNode): JsonNode =
    requests.add p
    if "invoice is wrong" in $p["state"]:
      inc attempts
      if attempts == 1:
        raise newException(JevTransportError, "connection reset")
    answerAll(p, 0.94))

  var got: seq[string]
  withEachState t in tickets:
    if t.message.feels "Is this time-sensitive?":
      got.add t.id

  doAssert attempts == 2                    # failed once, rescheduled, succeeded
  doAssert got == @["A", "B", "C"]

block a_permanently_retryable_failure_gives_up_and_parks:
  install(proc (p: JsonNode): JsonNode =
    requests.add p
    if "invoice is wrong" in $p["state"]:
      raise newException(JevTransportError, "connection reset")
    answerAll(p, 0.94))

  var raised = false
  withEachState t in tickets:
    let urgent = t.message.feels "Is this time-sensitive?"
    if t.id == "C":
      try: discard urgent.probability
      except JevTransportError: raised = true
    else:
      doAssert urgent.probability == 0.94

  doAssert raised                           # one reschedule, then parked

# ---------------------------------------------------------------- unchanged

block withstate_still_takes_one_request:
  install(proc (p: JsonNode): JsonNode =
    requests.add p
    answerAll(p, 0.94))

  let ticket = tickets[0]
  withState ticket:
    discard ticket.message.feels "Is this time-sensitive?"
    discard ticket.message.feels "Is the sender angry?"

  doAssert requests.len == 1
  doAssert requests[0]["questions"].len == 2

# ---------------------------------------------------------------- the wire

block requests_really_overlap:
  # Every block above uses the stub transport, which never reaches `postAsync`.
  # This is the only check that `submitAll` has more than one request in flight:
  # a server that sleeps before answering, so sequential and concurrent differ by
  # more than noise.
  const
    Delay = 200   ## ms the server sits on each request
    Count = 4     ## one full wave at the current in-flight width

  let server = newAsyncHttpServer()
  server.listen(Port(0))
  let port = server.getPort()

  proc serve() {.async.} =
    while true:
      await server.acceptRequest(proc (req: Request) {.async.} =
        await sleepAsync(Delay)
        await req.respond(Http200, $(%*{
          "model": "jev-1.13.0",
          "answers": {"x": {"type": "noul", "noul": 0.5}},
          "usage": {"input_tokens": 1, "output_tokens": 1}})))
  asyncCheck serve()

  var batches: seq[Batch]
  for i in 0 ..< Count:
    var b = initBatch("t", %*{"id": i})
    b.add QuestionSite(slug: "x", stateRoot: "t", primitive: pNoul,
                       instructions: focusedInstructions("", "question " & $i))
    batches.add b

  let client = newClient(apiKey = "k", endpoint = "http://127.0.0.1:" & $port.int)
  let started = epochTime()
  let answers = client.submitAll(batches)
  let elapsed = epochTime() - started

  doAssert answers.len == Count
  for a in answers:
    doAssert a.failure.isNil, "the local server should not fail: " & a.failure.msg
  # Sequentially this is Count * Delay. Half that is a wide enough margin to be
  # immune to scheduling noise while still failing outright if the wave is
  # serialised.
  doAssert elapsed < (Count * Delay).float / 2000.0,
    "requests did not overlap: " & $elapsed & "s for " & $Count &
    " requests of " & $Delay & "ms"

  # And the width is the caller's to change. One at a time against the same
  # server must take at least the sequential time, which is the only way to show
  # that `inFlight` is read rather than ignored.
  var serial = newSeq[Batch](Count)
  for i in 0 ..< Count:
    serial[i] = initBatch("t", %*{"id": i})
    serial[i].add QuestionSite(slug: "x", stateRoot: "t", primitive: pNoul,
                               instructions: focusedInstructions("", "question " & $i))
  client.inFlight = 1
  let oneAtATime = epochTime()
  discard client.submitAll(serial)
  doAssert epochTime() - oneAtATime >= (Count * Delay).float / 1000.0 * 0.9

  server.close()

block the_width_is_configurable:
  doAssert newClient(apiKey = "x").inFlight == DefaultInFlight

  putEnv("RECKONIM_IN_FLIGHT", "32")
  doAssert newClient(apiKey = "x").inFlight == 32

  for bad in ["0", "-3", "lots"]:
    putEnv("RECKONIM_IN_FLIGHT", bad)
    try:
      discard newClient(apiKey = "x")
      doAssert false, "RECKONIM_IN_FLIGHT=" & bad & " must be refused"
    except JevConfigError:
      discard
  delEnv("RECKONIM_IN_FLIGHT")

echo "ok"
