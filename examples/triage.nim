## Support ticket triage - the flagship ReckoNim example.
##
## Six judgments across all three Jev primitives, each written inside the
## expression that uses it: an `if` condition, an `and` operand, the branches of
## an `if` expression, a `.level` read. None of them is bound to a name first.
## The macro lifts all six out of those positions into one request, sends it, and
## puts each answer back where its judgment was written.
##
## That is the part a hand-written batch cannot do. Without it you write the six
## questions in one place and read the six answers in another, and keep the two
## lists in step by hand.
##
##   nix develop
##   export JEV_API_KEY=...
##   nim c -d:ssl --path:src -r examples/triage.nim
##
## Try it with the trace on to see the batching:
##   RECKONIM_TRACE=1 nim c -d:ssl --path:src -r examples/triage.nim
##
## Record a run, then replay it with no API key at all:
##   RECKONIM_RECORD=run.json nim c -d:ssl --path:src -r examples/triage.nim
##   RECKONIM_REPLAY=run.json ./examples/triage

import std/[json, strutils]
import reckonim

type
  Account = object
    plan: string
    mrrUsd: int
    tenureMonths: int
  Customer = object
    name: string
    account: Account
  Ticket = object
    id: string
    message: string
    customer: Customer

let ticket = Ticket(
  id: "T-104",
  message: "This is the fourth time I have written about this. Our payouts " &
           "have been failing for three days and nobody has replied. If this " &
           "is not fixed today we are cancelling.",
  customer: Customer(
    name: "Ada Okonkwo",
    account: Account(plan: "enterprise", mrrUsd: 9400, tenureMonths: 38)))

var actions: seq[string]

echo "ticket ", ticket.id, " from ", ticket.customer.name
echo "  \"", ticket.message[0 .. 58], "...\""

withState ticket:
  # In an `if` condition. The converter reads the answer at the judgment's own
  # threshold, which defaults to 0.5.
  if ticket.message.feels "Is the customer describing something time-sensitive?":
    actions.add "escalate to on-call"

  # Two judgments as the operands of one `and`. Both questions were sent; if the
  # first reads false the second is simply never read.
  if ticket.customer.feels(
       "Is this customer at risk of cancelling?",
       criteria = %*{
         "true": "States or implies intent to leave, or threatens cancellation",
         "false": "No indication of leaving"}) and
     ticket.customer.account.feels(
       "Is losing this account materially costly?",
       criteria = %*{
         "true": "Enterprise plan, high monthly revenue, or long tenure",
         "false": "Small, cheap, or new account"}):
    actions.add "assign named account manager"

  # As the condition of an `if` expression, inside a call argument. A high bar,
  # because the consequence of being wrong is a human never seeing the ticket.
  actions.add(
    if ticket.message.feels(
         "Can this be resolved by a templated reply with no human reading it?",
         atLeast = 0.95): "send templated reply"
    else: "queue for a human")

  # The one judgment here that is read twice, so it gets a name. `.value` is the
  # selection whatever the distribution looks like, so gate on confidence at a
  # level that matches the cost of being wrong.
  let team = ticket.message.choice(
    "Which team should handle this ticket?",
    %*{"billing":   "Payments, invoicing, refunds, payouts",
       "technical": "Bugs, outages, integrations, API errors",
       "sales":     "Pricing, upgrades, renewals, new accounts"})
  actions.add(
    if team.confidence > 0.8: "route to " & team.value
    else: "route to triage queue (team unclear, " &
          team.confidence.formatFloat(ffDecimal, 2) & ")")

  # `.level` read straight off the judgment, no binding in between.
  if ticket.message.score(
       "How frustrated is the customer?",
       %*["Calm and matter-of-fact",
          "Visibly annoyed",
          "Angry, with an explicit threat or ultimatum"]).level >= 2:
    actions.add "flag for tone-aware handling"

echo()
echo "actions"
for a in actions:
  echo "  - ", a
