## Phase 3 checks: the macro is syntax only, so these assert on what reaches the
## wire and how many requests it took.

import std/[json, os, strutils]
import reckonim

let ambientRecord = getEnv("RECKONIM_RECORD")
let ambientReplay = getEnv("RECKONIM_REPLAY")
delEnv("RECKONIM_RECORD")
delEnv("RECKONIM_REPLAY")

var requests: seq[JsonNode]

proc install(answer: JsonNode) =
  ## Every question gets the same answer body; we assert on the requests.
  requests = @[]
  globalClient = newClient(apiKey = "x", transport = proc (p: JsonNode): JsonNode =
    requests.add p
    var res = newJObject()
    for qid, q in p["questions"]:
      res[qid] = answer
    %*{"model": "jev-1.13.0", "answers": res,
       "usage": {"input_tokens": 400, "output_tokens": 50}})

let Yes = %*{"type": "noul", "noul": 0.94}
let No = %*{"type": "noul", "noul": 0.02}

proc questionOf(req: JsonNode, slug: string): JsonNode =
  for qid, q in req["questions"]:
    if slug in qid: return q
  nil

type
  Account = object
    plan: string
    tenureMonths: int
  Customer = object
    name: string
    account: Account
  Ticket = object
    message: string
    customer: Customer
    messages: seq[string]

proc sample(): Ticket =
  Ticket(message: "Payouts failing for three days. Cancel my account.",
         customer: Customer(name: "Ada",
                            account: Account(plan: "enterprise", tenureMonths: 38)),
         messages: @["thanks!", "this is unacceptable", "quick question"])

# ---------------------------------------------------------------- batching

block siblings_share_one_request:
  install(Yes)
  let ticket = sample()
  var hits = 0
  withState ticket:
    if ticket.message.feels "Is this urgent?": inc hits
    if ticket.message.feels "Is the sender angry?": inc hits
    if ticket.customer.feels "Is this customer likely to churn?": inc hits
  doAssert hits == 3
  doAssert requests.len == 1                    # three judgments, one round trip
  doAssert requests[0]["questions"].len == 3
  doAssert requests[0]["state"]["message"].getStr.startsWith("Payouts")

block judgments_in_untaken_branches_still_batch:
  # Speculative fan-out: the `angry` question rides along even though control
  # flow never reaches its site. Jev's own recommended pattern, and measured to
  # cost no latency.
  install(No)
  let ticket = sample()
  withState ticket:
    if ticket.message.feels "Is this urgent?":
      if ticket.message.feels "Is the sender angry?":
        discard
  doAssert requests.len == 1
  doAssert requests[0]["questions"].len == 2
  doAssert questionOf(requests[0], "is_the_sender_angry") != nil

block focus_path_and_criteria_reach_the_wire:
  install(Yes)
  let ticket = sample()
  withState ticket:
    if ticket.customer.account.plan.feels("Is this a high-risk account to lose?",
        criteria = %*{"true": "Large or long-tenured", "false": "Small or new"}):
      discard
  let q = questionOf(requests[0], "high_risk")
  doAssert q["instructions"]["inspect"].getStr == "customer.account.plan"
  doAssert q["criteria"]["true"].getStr == "Large or long-tenured"

block receiver_as_root_omits_inspect:
  install(Yes)
  let ticket = sample()
  withState ticket:
    if ticket.feels "Is this ticket actionable?": discard
  for qid, q in requests[0]["questions"]:
    doAssert "inspect" notin q["instructions"]        # the receiver *is* the state
    doAssert qid.startsWith("is_this_ticket@ticket#")

block all_three_primitives_in_one_request:
  install(Yes)
  let ticket = sample()
  withState ticket:
    let urgent = ticket.message.feels "Is this urgent?"
    let team = ticket.message.choice("Which team should handle this?",
      %*{"billing": "b", "technical": "t"})
    let anger = ticket.message.score("How frustrated is the customer?",
      %*["Calm", "Frustrated", "Very angry"])
    doAssert urgent.probability == 0.94
    doAssert team.id.len > 0 and anger.id.len > 0
  doAssert requests.len == 1
  doAssert requests[0]["questions"].len == 3

block duplicate_judgments_dedup_across_sites:
  install(Yes)
  let ticket = sample()
  withState ticket:
    if ticket.message.feels "Is this urgent?": discard
    if ticket.message.feels "Is this urgent?": discard
  doAssert requests[0]["questions"].len == 1    # two sites, one question

block nested_withstate_is_a_separate_request:
  install(Yes)
  let ticket = sample()
  let reply = "We have escalated your payout issue."
  withState ticket:
    if ticket.message.feels "Is this urgent?":
      withState reply:
        if reply.feels "Is this reply appropriate?": discard
  doAssert requests.len == 2
  doAssert requests[0]["questions"].len == 1
  doAssert requests[1]["state"].getStr.startsWith("We have escalated")

block state_is_snapshotted_at_entry:
  install(Yes)
  var ticket = sample()
  withState ticket:
    ticket.message = "mutated after entry"
    if ticket.message.feels "Is this urgent?": discard
  doAssert requests[0]["state"]["message"].getStr.startsWith("Payouts")

block tuple_state_serialises_and_roots:
  # usage-rules hard rule 2: bind a tuple to judge several values against each
  # other. std/json has no `%` for tuples, so toState goes through jsonutils.
  install(Yes)
  let change = (diff: "-  raise\n+  discard", message: "tidy up")
  withState change:
    if change.feels "Does the message describe the diff?": discard
    if change.diff.feels "Does this touch error handling?": discard
  doAssert requests.len == 1
  doAssert requests[0]["state"]["message"].getStr == "tidy up"
  doAssert questionOf(requests[0], "touch_error")["instructions"]["inspect"].getStr == "diff"

# ---------------------------------------------------------------- loops

block loop_index_evaluates_per_iteration:
  # PLAN.md section 12: a runtime focus path is correct but unbatched in the MVP.
  # One request per iteration, and the focus path carries the index in brackets.
  install(Yes)
  let ticket = sample()
  var seen: seq[string]
  withState ticket:
    for i in 0 ..< ticket.messages.len:
      if ticket.messages[i].feels "Is this message angry?":
        seen.add $i
  doAssert seen.len == 3
  doAssert requests.len == 3                     # unbatched, deliberately
  for idx, req in requests:
    let q = questionOf(req, "is_this_message_angry")
    doAssert q["instructions"]["inspect"].getStr == "messages[" & $idx & "]"

block constant_index_is_hoisted:
  install(Yes)
  let ticket = sample()
  withState ticket:
    if ticket.messages[1].feels "Is this message angry?": discard
    if ticket.message.feels "Is this urgent?": discard
  doAssert requests.len == 1                     # literal index, so it batches
  doAssert questionOf(requests[0], "is_this_message_angry")["instructions"]["inspect"].getStr ==
           "messages[1]"

# Compile-time rejections live in tests/fail/ - the macro calls `error()`, which
# aborts compilation outright and so cannot be caught by `compiles()`. `nimble
# test` compiles those files and asserts they fail with the right message.

# ---------------------------------------------------------------- live

block live:
  if getEnv("RECKONIM_LIVE").len > 0:
    if ambientRecord.len > 0: putEnv("RECKONIM_RECORD", ambientRecord)
    if ambientReplay.len > 0: putEnv("RECKONIM_REPLAY", ambientReplay)
    globalClient = newClient()

    let ticket = sample()
    var actions: seq[string]

    withState ticket:
      if ticket.message.feels "Is this urgent?":
        actions.add "escalate"
      if ticket.customer.feels "Is this customer likely to churn?":
        actions.add "retain"
      if ticket.message.feels("Is this safe to auto-reply to?", atLeast = 0.95):
        actions.add "autoreply"
      let team = ticket.message.choice("Which team should handle this?", %*{
        "billing": "Payments, invoicing, refunds, payouts",
        "technical": "Bugs, outages, integrations",
        "sales": "Pricing, upgrades, new accounts"})
      let anger = ticket.message.score("How frustrated is the customer?",
        %*["Calm", "Frustrated", "Very angry"])
      actions.add "route:" & team.value
      actions.add "anger:" & $anger.level

    doAssert "escalate" in actions
    doAssert "retain" in actions
    doAssert "autoreply" notin actions
    doAssert "route:billing" in actions
    doAssert "anger:2" in actions
    echo "live: ", actions.join(" ")

echo "ok"
