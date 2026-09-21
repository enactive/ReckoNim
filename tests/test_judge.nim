## Phase 2 checks. Stub transport throughout; live section at the bottom.

import std/[json, os, strutils, tables]
import reckonim

let ambientRecord = getEnv("RECKONIM_RECORD")
let ambientReplay = getEnv("RECKONIM_REPLAY")
delEnv("RECKONIM_RECORD")
delEnv("RECKONIM_REPLAY")

var requests: seq[JsonNode]

proc stubbed(answers: openArray[(string, JsonNode)]): Client =
  ## A transport that answers by slug: whichever queued question's id starts with
  ## the given slug gets the given answer body.
  let table = @answers
  newClient(apiKey = "x", transport = proc (p: JsonNode): JsonNode =
    requests.add p
    var res = newJObject()
    for qid, q in p["questions"]:
      for (slug, body) in table:
        if qid.startsWith(slug & "@"):
          res[qid] = body
    %*{"model": "jev-1.13.0", "answers": res,
       "usage": {"input_tokens": 400, "output_tokens": 50}})

proc newTestSession(answers: openArray[(string, JsonNode)]): Session =
  # Every focus path used below must resolve in this snapshot, or the judgment is
  # dropped before it is sent - see tests/test_focus.nim.
  requests = @[]
  newSession(stubbed(answers), "ticket", %*{
    "message": "Payouts failing.",
    "customer": {"account": {"plan": "enterprise"}}})

let
  Urgent = %*{"type": "noul", "noul": 0.94}
  Team = %*{"type": "choice", "choice": "billing", "confidence": 0.82,
            "probabilities": {"billing": 0.82, "technical": 0.1, "sales": 0.08}}
  Anger = %*{"type": "score", "score": 1.0, "confidence": 0.5,
             "legend": {"0": "Calm", "1": "Frustrated", "2": "Very angry"},
             "probabilities": {"0": 0.45, "1": 0.1, "2": 0.45}}

# ---------------------------------------------------------------- the core safety property

block reading_before_run_raises:
  # The failure that must never be silent: a judgment has no value until its
  # batch is sent. Coercing to false here would be the worst possible default.
  let s = newTestSession({"urgent": Urgent})
  let urgent = s.feels("message", "Is this urgent?")
  var raised = false
  try: discard urgent.value
  except UnresolvedError: raised = true
  doAssert raised

  raised = false
  try:
    if urgent: discard          # the converter must raise too, not yield false
  except UnresolvedError: raised = true
  doAssert raised

block adding_after_run_raises:
  let s = newTestSession({"urgent": Urgent})
  discard s.feels("message", "Is this urgent?")
  s.run()
  var raised = false
  try: discard s.feels("message", "Is this angry?")
  except UnresolvedError as e:
    raised = true
    doAssert "never be answered" in e.msg
  doAssert raised

# ---------------------------------------------------------------- one request

block many_judgments_one_request:
  let s = newTestSession({"urgent": Urgent, "team": Team, "anger": Anger})
  let urgent = s.feels("message", "Is this urgent?", slug = "urgent")
  let team = s.choice("message", "Which team?",
    %*{"billing": "b", "technical": "t", "sales": "s"}, slug = "team")
  let anger = s.score("message", "How frustrated?",
    %*["Calm", "Frustrated", "Very angry"], slug = "anger")
  doAssert s.pending == 3
  s.run()
  doAssert requests.len == 1                     # three judgments, one round trip
  doAssert requests[0]["questions"].len == 3
  doAssert urgent.value
  doAssert team.value == "billing"
  doAssert anger.value == 1.0

block run_is_idempotent:
  let s = newTestSession({"urgent": Urgent})
  discard s.feels("message", "Is this urgent?")
  s.run()
  s.run()
  doAssert requests.len == 1

# ---------------------------------------------------------------- thresholds

block threshold_gates_coercion:
  let s = newTestSession({"urgent": Urgent})       # noul 0.94
  let lax = s.feels("message", "Is this urgent?", slug = "urgent")
  let strict = s.feels("message", "Is this urgent?", slug = "urgent", atLeast = 0.99)
  s.run()
  doAssert lax.probability == 0.94
  doAssert lax.value                               # 0.94 >= 0.5
  doAssert not strict.value                        # 0.94 <  0.99
  doAssert lax.atLeast(0.99) == false              # per-read gating, same question

block threshold_is_not_part_of_the_question:
  # Two judgments differing only in coercion policy ask one question. The
  # threshold is client-side policy; it must not reach the wire or the id.
  let s = newTestSession({"urgent": Urgent})
  let a = s.feels("message", "Is this urgent?", slug = "urgent")
  let b = s.feels("message", "Is this urgent?", slug = "urgent", atLeast = 0.99)
  doAssert a.id == b.id
  doAssert s.pending == 1
  s.run()
  doAssert requests[0]["questions"].len == 1
  doAssert a.value and not b.value                 # one answer, two policies

block identical_judgments_dedup:
  let s = newTestSession({"urgent": Urgent})
  let a = s.feels("message", "Is this urgent?", slug = "urgent", loc = "t.nim:10")
  let b = s.feels("message", "Is this urgent?", slug = "urgent", loc = "t.nim:20")
  doAssert a.id == b.id and s.pending == 1
  s.run()
  doAssert a.value == b.value

# ---------------------------------------------------------------- the three distinctions

block score_is_not_argmax:
  # PLAN.md section 7. probabilities {0:0.45, 1:0.1, 2:0.45} -> mean 1.0, but no
  # level 1 ever won. Rounding `value` would report a level with 10% probability.
  let s = newTestSession({"anger": Anger})
  let anger = s.score("message", "How frustrated?",
    %*["Calm", "Frustrated", "Very angry"], slug = "anger")
  s.run()
  doAssert anger.value == 1.0
  doAssert anger.level == 0
  doAssert anger.level != int(anger.value)
  doAssert anger.legend["2"].getStr == "Very angry"

block noul_confidence_raises:
  let s = newTestSession({"urgent": Urgent})
  let urgent = s.feels("message", "Is this urgent?", slug = "urgent")
  s.run()
  var raised = false
  try: discard urgent.confidence
  except JevProtocolError as e:
    raised = true
    doAssert "noul" in e.msg
  doAssert raised

block choice_value_is_not_gated:
  # `.value` is the selection whatever the distribution looks like. Gating is the
  # caller's call, at a threshold matched to the consequence.
  let s = newTestSession({"team": Team})
  let team = s.choice("message", "Which team?", %*{"billing": "b"}, slug = "team")
  s.run()
  doAssert team.value == "billing"
  doAssert team.confidence == 0.82
  doAssert team.probabilities["technical"] == 0.1
  doAssert not (team.confidence > 0.9)             # caller would route to review

# ---------------------------------------------------------------- wire shape

block criteria_and_focus_reach_the_wire:
  let s = newTestSession({"spam": Urgent})
  let spam = s.feels("customer.account.plan", "Is this spam?", slug = "spam",
    criteria = %*{"true": "Unsolicited bulk", "false": "Genuine contact"})
  s.run()
  let q = requests[0]["questions"][spam.id]
  doAssert q["type"].getStr == "noul"
  doAssert q["instructions"]["inspect"].getStr == "customer.account.plan"
  doAssert q["instructions"]["question"].getStr == "Is this spam?"
  doAssert q["criteria"]["true"].getStr == "Unsolicited bulk"
  doAssert spam.id.startsWith("spam@ticket.customer.account.plan#")

block slug_defaults_from_the_question:
  let s = newTestSession({"is_this_urgent": Urgent})
  let j = s.feels("message", "Is this urgent?")
  doAssert j.id.startsWith("is_this_urgent@ticket.message#")
  s.run()
  doAssert j.value

block score_rejects_map_criteria:
  # The service returns 422 for this; fail earlier with a clearer message.
  let s = newTestSession({"anger": Anger})
  var raised = false
  try: discard s.score("message", "How frustrated?", %*{"0": "Calm"})
  except JevError as e:
    raised = true
    doAssert "ordered list" in e.msg
  doAssert raised

# ---------------------------------------------------------------- live

block live:
  if getEnv("RECKONIM_LIVE").len > 0:
    if ambientRecord.len > 0: putEnv("RECKONIM_RECORD", ambientRecord)
    if ambientReplay.len > 0: putEnv("RECKONIM_REPLAY", ambientReplay)

    let s = newSession(newClient(), "ticket", %*{
      "message": "Fourth time writing. Payouts failing three days. Cancel my account.",
      "customer": {"account": {"plan": "enterprise", "tenure_months": 38}}})

    let urgent = s.feels("message", "Is this urgent?")
    let churn = s.feels("customer", "Is this customer about to churn?")
    let safe = s.feels("message", "Is this message safe to auto-reply to?", atLeast = 0.95)
    let team = s.choice("message", "Which team should handle this?",
      %*{"billing": "Payments, invoicing, refunds, payouts",
         "technical": "Bugs, outages, integrations",
         "sales": "Pricing, upgrades, new accounts"})
    let anger = s.score("message", "How frustrated is the customer?",
      %*["Calm", "Frustrated", "Very angry"])

    s.run()

    doAssert urgent                                  # converter, live
    doAssert churn.probability > 0.5
    doAssert not safe                                # high bar, angry message
    doAssert team.value == "billing"
    doAssert anger.level == 2
    echo "live: ", s.pending, " questions in 1 request | urgent=", urgent.probability,
         " churn=", churn.probability, " safe=", safe.probability,
         " team=", team.value, "@", team.confidence,
         " anger=", anger.level, "/", anger.value

echo "ok"
