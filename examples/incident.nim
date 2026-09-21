## `.level` is not `round(.value)`.
##
## A score answer is a distribution over the levels you supplied. `.value` is
## its probability-weighted mean; `.level` is its argmax. They are different
## numbers, and when the distribution is bimodal the mean lands in the trough -
## on a level almost nothing voted for.
##
## This alert is the case that produces one. It is either the chaos drill
## overrunning (do nothing) or a region that is actually gone (page someone).
## "Ticket it for business hours" is the one response that is wrong either way,
## so the mass splits around it - and the mean lands right on top of it.
##
##   nim c -d:ssl --path:src -r examples/incident.nim
##
## Replays a committed recording by default, so the distribution is the one this
## file was written against. Against the live service:
##
##   RECKONIM_LIVE=1 nim c -d:ssl --path:src -r examples/incident.nim
##
## A live run will not reproduce these exact numbers, and may not come back
## bimodal at all. The arithmetic being shown is ReckoNim's, not the service's.

import std/[json, os, strutils]
import reckonim

const recording = currentSourcePath().parentDir / "incident.replay.json"

if getEnv("RECKONIM_LIVE").len == 0 and getEnv("RECKONIM_RECORD").len == 0:
  putEnv("RECKONIM_REPLAY", recording)

type Alert = object
  service: string
  log: string

let alert = Alert(
  service: "orders",
  log: """
calendar: chaos drill "region-evac" booked 22:00-23:00
23:04:11 eu-west-1 orders-api: 0/12 instances healthy
23:04:12 traffic shifted to eu-central-1, order_success_rate unchanged
23:06:02 eu-west-1 still 0/12 healthy
drill owner unreachable; no confirmation either way
""")

withState alert:
  let sev = alert.log.score(
    "How should on-call respond to this right now?",
    %*["Ignore: this is the scheduled drill, nothing is actually broken",
       "Ticket it for business hours",
       "Page on-call now: a region is genuinely down"])

  echo "alert on ", alert.service
  echo()

  echo "distribution"
  for k, p in sev.probabilities:
    echo "  ", k, "  ", p.formatFloat(ffDecimal, 2), "  ",
         "#".repeat(int(p * 20)).alignLeft(21), sev.legend[k].getStr
  echo()

  echo "  .value          ", sev.value.formatFloat(ffDecimal, 2),
       "    probability-weighted mean of the level indices"
  echo "  .level          ", sev.level,
       "       the most likely level"
  # Measured: a point-mass answer reports 1.00, this one reports 0.00. It is the
  # service's own certainty, reported alongside the distribution rather than
  # derived from it - do not reconstruct it from `.probabilities`.
  echo "  .confidence     ", sev.confidence.formatFloat(ffDecimal, 2),
       "    the service's certainty in the answer as a whole"
  echo()

  # The misuse. `round` turns a mean into a level, and here the level it
  # produces is the one the model was least willing to pick.
  let rounded = int(sev.value + 0.5)
  echo "  round(.value) = ", rounded, ", which holds ",
       sev.probabilities[$rounded].formatFloat(ffDecimal, 2), " of the mass."
  if rounded != sev.level:
    echo "  .level        = ", sev.level, ", which holds ",
         sev.probabilities[$sev.level].formatFloat(ffDecimal, 2), "."
    echo "  Routing on the first one tickets an outage for the morning."
  echo()

  # Route on the argmax, and let confidence say whether to trust it.
  const actions = ["close as expected drill noise",
                   "open a ticket for business hours",
                   "page the on-call engineer"]
  echo "action: ", actions[sev.level]
  if sev.confidence < 0.6:
    echo "        (confidence ", sev.confidence.formatFloat(ffDecimal, 2),
         " - the alert is genuinely ambiguous; the runbook should say which way to fail)"

  # `.value` is not useless - it is the right number to average, trend or
  # threshold across many alerts. It is only wrong as a level.
  echo()
  echo "keep .value for aggregates (mean severity over a week), .level to act on one."
