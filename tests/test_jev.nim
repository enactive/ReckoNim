## Phase 1 checks. Plain doAssert, a stub transport, no framework.
## The live test at the bottom runs only with RECKONIM_LIVE=1 and a JEV_API_KEY.

import std/[json, os, strutils, tables]
import reckonim

# Record/replay are process-global by design, so an ambient setting would leak
# into every client below and override injected stubs. Park them for the unit
# blocks; the live section re-applies them.
let ambientRecord = getEnv("RECKONIM_RECORD")
let ambientReplay = getEnv("RECKONIM_REPLAY")
delEnv("RECKONIM_RECORD")
delEnv("RECKONIM_REPLAY")

proc site(slug, focus, question: string, loc = "t.nim:1",
          criteria: JsonNode = nil, prim = pNoul): QuestionSite =
  QuestionSite(slug: slug, stateRoot: "ticket", focusPath: focus, primitive: prim,
               instructions: focusedInstructions(focus, question),
               criteria: criteria, sourceLocation: loc)

# ---------------------------------------------------------------- canonical JSON

block canonical_is_order_independent:
  var a = newJObject(); a["z"] = %1; a["a"] = %2
  var b = newJObject(); b["a"] = %2; b["z"] = %1
  doAssert canonical(a) == canonical(b)
  doAssert canonical(%*{"n": [3, 1, 2]}) == """{"n":[3,1,2]}"""  # arrays stay ordered

# ---------------------------------------------------------------- identity

block id_ignores_source_location:
  # The point of excluding sourceLocation: unrelated edits move line numbers and
  # must not invalidate a recording.
  doAssert site("urgent", "message", "Is this urgent?", loc = "t.nim:17").id ==
           site("urgent", "message", "Is this urgent?", loc = "t.nim:948").id

block id_tracks_meaning:
  let base = site("urgent", "message", "Is this urgent?")
  doAssert base.id != site("urgent", "message", "Is this angry?").id
  doAssert base.id != site("urgent", "customer", "Is this urgent?").id
  doAssert base.id != site("urgent", "message", "Is this urgent?", prim = pChoice).id
  doAssert base.id != site("urgent", "message", "Is this urgent?",
                           criteria = %*{"true": "x", "false": "y"}).id

block id_is_readable_and_wire_safe:
  let s = site("urgent", "customer.account.plan", "high risk?")
  doAssert s.id.startsWith("urgent@ticket.customer.account.plan#")
  doAssert s.id.split('#')[1].len == 8

block slugify_clips_and_separates:
  doAssert slugify("Is this urgent?") == "is_this_urgent"
  doAssert slugify("  ...  ") == ""
  doAssert slugify("a".repeat(80)).len <= 24

# ---------------------------------------------------------------- focus paths

block empty_focus_omits_inspect:
  # `withState reply:` over a bare string - the receiver *is* the state.
  doAssert "inspect" notin focusedInstructions("", "Is it appropriate?")
  doAssert focusedInstructions("message", "q")["inspect"].getStr == "message"

# ---------------------------------------------------------------- batching

block identical_sites_dedup:
  var b = initBatch("ticket", %*{"message": "hi"})
  let id1 = b.add site("urgent", "message", "Is this urgent?", loc = "t.nim:10")
  let id2 = b.add site("urgent", "message", "Is this urgent?", loc = "t.nim:20")
  doAssert id1 == id2
  doAssert b.sites.len == 1            # one question on the wire, two source sites
  doAssert b.toRequest["questions"].len == 1

block distinct_sites_coexist:
  var b = initBatch("ticket", %*{"message": "hi"})
  b.add site("urgent", "message", "Is this urgent?")
  b.add site("angry", "message", "Is this angry?")
  b.add site("team", "message", "Which team?", prim = pChoice,
             criteria = %*{"billing": "b", "sales": "s"})
  doAssert b.sites.len == 3
  let req = b.toRequest
  doAssert req["state"]["message"].getStr == "hi"
  doAssert req["model"].getStr == DefaultModel
  doAssert req["questions"].len == 3

block id_collision_raises:
  # The failure hash8 cannot rule out: one id, two different meanings. Seeding a
  # foreign site under the id `add` will compute exercises the real guard.
  var b = initBatch("ticket", %*{"message": "hi"})
  let s = site("urgent", "message", "Is this urgent?", loc = "t.nim:10")
  let impostor = site("urgent", "message", "Something else entirely", loc = "t.nim:99")
  b.sites[s.id] = impostor
  var raised = false
  try: b.add s
  except JevIdCollisionError as e:
    raised = true
    doAssert "t.nim:10" in e.msg and "t.nim:99" in e.msg
  doAssert raised

block empty_batch_rejected:
  var b = initBatch("ticket", %*{"message": "hi"})
  var raised = false
  try: discard newClient(apiKey = "x").submit(b)
  except JevLimitError: raised = true
  doAssert raised

# ---------------------------------------------------------------- limits

block oversized_state_rejected:
  var b = initBatch("ticket", %*{"message": "x".repeat(200_000)})
  b.add site("urgent", "message", "Is this urgent?")
  var raised = false
  try: b.checkLimits()
  except JevLimitError as e:
    raised = true
    doAssert "ticket" in e.msg and "urgent" in e.msg
  doAssert raised

block normal_batch_passes_limits:
  var b = initBatch("ticket", %*{"message": "Payouts failing for three days."})
  for i in 0 ..< 60:
    b.add site("q" & $i, "message", "Sentiment " & $i & "?")
  b.checkLimits()

# ---------------------------------------------------------------- answers

const StubBody = """
{ "model": "jev-1.13.0",
  "answers": {
    "u": {"type": "noul", "noul": 0.94},
    "t": {"type": "choice", "choice": "billing", "confidence": 1.0,
          "probabilities": {"billing": 1.0, "technical": 0.0, "sales": 0.0}},
    "s": {"type": "score", "score": 1.0, "confidence": 0.6,
          "legend": {"0": "Calm", "1": "Frustrated", "2": "Very angry"},
          "probabilities": {"0": 0.45, "1": 0.1, "2": 0.45}}
  },
  "usage": {"input_tokens": 626, "output_tokens": 149} }
"""

block answer_accessors:
  let a = parseAnswers(parseJson(StubBody))
  doAssert a.model == "jev-1.13.0"
  doAssert a.inputTokens == 626
  doAssert a.noul("u") == 0.94
  doAssert a.choice("t") == "billing"
  doAssert a.confidence("t") == 1.0
  doAssert a.probabilities("t")["billing"] == 1.0
  doAssert a.legend("s")["2"].getStr == "Very angry"

block score_is_not_argmax:
  # PLAN.md section 7. probabilities {0:0.45, 1:0.1, 2:0.45} has expected value
  # 1.0 while the most likely level is 0. Rounding `score` would report level 1,
  # which no level actually won. These must stay separate accessors.
  let a = parseAnswers(parseJson(StubBody))
  doAssert a.score("s") == 1.0
  doAssert a.level("s") == 0
  doAssert a.level("s") != int(a.score("s"))

block noul_has_no_confidence:
  # Must raise, not default to something plausible.
  let a = parseAnswers(parseJson(StubBody))
  var raised = false
  try: discard a.confidence("u")
  except JevProtocolError as e:
    raised = true
    doAssert "noul" in e.msg
  doAssert raised

block malformed_score_raises_not_segfaults:
  # A 2xx body missing `probabilities` or `legend` used to reach a nil JsonNode
  # in `level`/`legend` and crash with SIGSEGV.
  let a = parseAnswers(%*{"model": "m", "answers": {
    "bare": {"type": "score", "score": 1.0, "confidence": 0.6}},
    "usage": {"input_tokens": 1, "output_tokens": 1}})
  for read in [proc () = discard a.level("bare"),
               proc () = discard a.probabilities("bare"),
               proc () = discard a.legend("bare")]:
    var raised = false
    try: read()
    except JevProtocolError as e:
      raised = true
      doAssert "score" in e.msg
    doAssert raised

block missing_answer_raises:
  let a = parseAnswers(parseJson(StubBody))
  var raised = false
  try: discard a.noul("nope")
  except JevProtocolError: raised = true
  doAssert raised

block malformed_response_raises:
  var raised = false
  try: discard parseAnswers(%*{"oops": true})
  except JevProtocolError: raised = true
  doAssert raised

# ---------------------------------------------------------------- transport

block stub_transport_sees_the_request:
  var seen: JsonNode
  let c = newClient(apiKey = "x", transport = proc (p: JsonNode): JsonNode =
    seen = p
    parseJson(StubBody))
  var b = initBatch("ticket", %*{"message": "hi"})
  let uid = b.add site("urgent", "message", "Is this urgent?")
  discard c.submit(b)
  doAssert seen["state"]["message"].getStr == "hi"
  doAssert uid in seen["questions"]
  doAssert seen["questions"][uid]["instructions"]["inspect"].getStr == "message"

# ---------------------------------------------------------------- record / replay

block record_then_replay_round_trips:
  let path = getTempDir() / "reckonim_record_test.json"
  removeFile(path)
  defer: removeFile(path)

  var calls = 0
  proc stub(p: JsonNode): JsonNode =
    # Answer the ids actually asked, the way the service does.
    calls.inc
    var answers = newJObject()
    for qid, q in p["questions"]:
      answers[qid] = %*{"type": q["type"].getStr, "noul": 0.94}
    %*{"model": "jev-1.13.0", "answers": answers,
       "usage": {"input_tokens": 327, "output_tokens": 20}}

  proc freshBatch(): Batch =
    result = initBatch("ticket", %*{"message": "hi"})
    result.add site("urgent", "message", "Is this urgent?")

  let uid = site("urgent", "message", "Is this urgent?").id

  putEnv("RECKONIM_RECORD", path)
  var rec = freshBatch()
  let recorded = newClient(apiKey = "x", transport = stub).submit(rec)
  delEnv("RECKONIM_RECORD")
  doAssert calls == 1
  doAssert fileExists(path)

  putEnv("RECKONIM_REPLAY", path)
  var rep = freshBatch()
  let replayed = newClient(apiKey = "x", transport = stub).submit(rep)
  delEnv("RECKONIM_REPLAY")
  doAssert calls == 1                       # replay never reached the transport
  doAssert replayed.noul(uid) == recorded.noul(uid)

block replay_miss_raises:
  let path = getTempDir() / "reckonim_replay_empty.json"
  writeFile(path, "[]")
  defer: removeFile(path)
  putEnv("RECKONIM_REPLAY", path)
  defer: delEnv("RECKONIM_REPLAY")
  var b = initBatch("ticket", %*{"message": "hi"})
  b.add site("urgent", "message", "Is this urgent?")
  var raised = false
  try: discard newClient(apiKey = "x").submit(b)
  except ReplayMissError as e:
    raised = true
    doAssert "ticket" in e.msg
  doAssert raised                            # a miss is an error, never a passthrough

block missing_replay_file_raises:
  putEnv("RECKONIM_REPLAY", getTempDir() / "definitely_not_here.json")
  defer: delEnv("RECKONIM_REPLAY")
  var raised = false
  try: discard newClient(apiKey = "x")
  except ReplayMissError: raised = true
  doAssert raised

# ---------------------------------------------------------------- live

block live:
  if getEnv("RECKONIM_LIVE").len > 0:
    if ambientRecord.len > 0: putEnv("RECKONIM_RECORD", ambientRecord)
    if ambientReplay.len > 0: putEnv("RECKONIM_REPLAY", ambientReplay)
    if ambientReplay.len == 0 and getEnv("JEV_API_KEY").len == 0:
      raise newException(JevError, "RECKONIM_LIVE set but no JEV_API_KEY and no replay file")

    var b = initBatch("ticket", %*{
      "message": "Fourth time writing. Payouts failing three days. Cancel my account.",
      "customer": {"account": {"plan": "enterprise", "tenure_months": 38}}})
    let urgent = b.add site("urgent", "message", "Is this urgent?")
    let angry = b.add site("angry", "message", "Is the sender angry?")
    let team = b.add site("team", "message", "Which team should handle this?",
      prim = pChoice,
      criteria = %*{"billing": "Payments, invoicing, refunds, payouts",
                    "technical": "Bugs, outages, integrations",
                    "sales": "Pricing, upgrades, new accounts"})
    let anger = b.add site("anger", "message", "How frustrated is the customer?",
      prim = pScore, criteria = %*["Calm", "Frustrated", "Very angry"])

    let a = newClient().submit(b)
    doAssert a.noul(urgent) > 0.5
    doAssert a.noul(angry) > 0.5
    doAssert a.choice(team) == "billing"
    doAssert a.level(anger) == 2
    doAssert a.inputTokens > 0
    echo "live: ", b.sites.len, " questions, 1 request, ",
         a.inputTokens, " input tokens, urgent=", a.noul(urgent),
         " team=", a.choice(team), " anger=", a.level(anger), "/", a.score(anger)

echo "ok"
