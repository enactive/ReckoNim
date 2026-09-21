## Where the code stops and the judgment starts.
##
## A vendor questionnaire is half structured and half prose. The structured half
## is not a judgment: `vendor.employees >= 500` is a comparison, it is exact,
## free, and cannot be wrong about a number that is sitting right there. Sending
## it to Jev buys nothing and can lose.
##
## The prose half is the opposite. "Does this answer dodge the question?" has no
## comparison that decides it.
##
##   RECKONIM_TRACE=1 nim c -d:ssl --path:src -r examples/rfp.nim
##
## The code checks run first and print no trace line, because they are not
## requests. If any of them fails hard the block never runs - the cheapest
## question is the one you do not send.

import std/json
import reckonim

type
  Answer = object
    question: string
    answer: string
  Vendor = object
    name: string
    employees: int
    soc2Expiry: string      ## ISO date; see reviewDate below
    dataRegions: seq[string]
    uptimeSlaPct: float
    annualPriceUsd: int
    answers: seq[Answer]

const
  reviewDate = "2026-09-19"
  requiredRegion = "eu-west"
  budgetUsd = 250_000

let vendor = Vendor(
  name: "Northwind Systems",
  employees: 1_240,
  soc2Expiry: "2027-02-28",
  dataRegions: @["eu-west", "us-east"],
  uptimeSlaPct: 99.95,
  annualPriceUsd: 198_000,
  answers: @[
    Answer(question: "Describe your incident response process.",
           answer: "Northwind maintains a mature, industry-leading incident " &
                   "response capability aligned to best practices. Our teams " &
                   "are empowered to respond rapidly to any event."),
    Answer(question: "How do you handle a customer request to delete all " &
                     "their data, and how long does it take?",
           answer: "Deletion requests are handled through our standard " &
                   "process. We take data privacy extremely seriously and " &
                   "are fully committed to compliance with applicable " &
                   "regulations."),
    Answer(question: "What happens to our data if you are acquired?",
           answer: "In the event of an acquisition, customer contracts " &
                   "transfer to the acquiring entity. Our DPA gives you 60 " &
                   "days to terminate without penalty and request export or " &
                   "deletion; we have done this twice, in 2021 and 2024.")])

# --- what code answers -------------------------------------------------------

# ponytail: ISO-8601 dates sort lexicographically, so a string compare is a date
# compare. Swap in std/times the day the format stops being ISO.
var checks: seq[(string, bool)] = @[
  ("employees >= 500", vendor.employees >= 500),
  ("SOC 2 valid at review date", vendor.soc2Expiry > reviewDate),
  ("hosts in " & requiredRegion, requiredRegion in vendor.dataRegions),
  ("uptime SLA >= 99.9%", vendor.uptimeSlaPct >= 99.9),
  ("within budget", vendor.annualPriceUsd <= budgetUsd)]

echo vendor.name
echo()
echo "code (0 requests, exact)"
var passedAll = true
for (name, ok) in checks:
  echo "  ", (if ok: "[x] " else: "[ ] "), name
  if not ok: passedAll = false

if not passedAll:
  echo()
  echo "fails a hard requirement - no judgments sent"
  quit 0

# --- what code cannot answer -------------------------------------------------

echo()
echo "judgment (1 request, probabilistic)"
echo()

var followUps: seq[string]

withState vendor:
  # Literal indices, so all four of these batch into the one request - and each
  # is written in the condition that acts on it, not bound above it.
  if vendor.answers[1].answer.feels(
       "Does this answer avoid committing to anything specific?",
       criteria = %*{
         "true": "Restates the question, cites commitment or compliance in " &
                 "general terms, and names no concrete process, timeframe or number",
         "false": "Names a specific mechanism, timeframe, or number"}):
    followUps.add "re-ask deletion: require a stated SLA in days"

  if not vendor.answers[2].answer.feels(
       "Does this answer describe something the vendor has actually done, " &
       "rather than something it intends to do?",
       criteria = %*{
         "true": "Refers to a specific past event, contract term, or dated instance",
         "false": "Describes only intent, policy, or capability"}):
    followUps.add "ask for the contract clause behind the acquisition answer"

  # The whole seq: the question is about the set of answers, not any one of them.
  if vendor.answers.score(
       "How much of this questionnaire is backed by specifics rather than assurance?",
       %*["Almost all assurance: adjectives, commitments, no checkable detail",
          "Mixed: some answers carry specifics, others are boilerplate",
          "Almost all specifics: processes, timeframes and numbers throughout"]
     ).level == 0:
    followUps.add "whole questionnaire is assurance - send back for specifics"

  # Two reads - the gate and the area named in the follow-up - so this one is
  # bound. A judgment read once does not need to be.
  let weakest = vendor.answers.choice(
    "Which area is this vendor least convincing about?",
    %*{"incident_response": "Detecting, escalating and resolving incidents",
       "data_deletion":     "Deleting customer data on request, and how fast",
       "continuity":        "What happens to the data if the company changes hands"})
  if weakest.confidence > 0.6:
    followUps.add "book the technical call on " & weakest.value

echo "follow-ups"
if followUps.len == 0:
  echo "  - none; proceed to reference calls"
for f in followUps:
  echo "  - ", f

echo()
echo "Note what was not asked. Nobody sent \"does this vendor have more than 500"
echo "employees?\" - the field is an int, the comparison is exact and free, and a"
echo "0.93 would be strictly worse than a `>=`."
