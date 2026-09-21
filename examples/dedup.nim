## Asking the same question twice costs one question.
##
## The point of writing a judgment where its answer is used is that independent
## rules do not have to coordinate. Three rules that each need "is this payout an
## exit scam?" each write it, at the bar their own action deserves. Nobody hoists
## a shared binding to the top of the block, and nobody has to.
##
## That only works if the duplicates collapse. They do: a question's identity is
## the normalized record - state root, focus path, primitive, instructions,
## criteria - hashed. Source location is deliberately not in it, and neither is
## `atLeast`, which is a coercion policy on the judgment rather than part of the
## question. So three sites at three thresholds are one question on the wire and
## one answer coming back, read three times.
##
## The counts below need no API key and send nothing: dedup happens while the
## batch is built, before anything leaves.
##
##   nim c -d:ssl --path:src -r examples/dedup.nim
##
## Ask for the live half and it goes on to run the `withState` form, where the
## trace reports one question for four sites:
##
##   export JEV_API_KEY=...
##   RECKONIM_LIVE=1 RECKONIM_TRACE=1 nim c -d:ssl --path:src -r examples/dedup.nim

import std/[json, os, strutils]
import reckonim

type Payout = object
  id: string
  amountUsd: int
  destination: string
  memo: string
  accountAgeDays: int

let payout = Payout(
  id: "P-8821",
  amountUsd: 41_500,
  destination: "newly added external account, added 40 minutes ago",
  memo: "final settlement, please process today, closing the business",
  accountAgeDays: 11)

# Sites collapse only if their question text matches exactly, so it lives in one
# place rather than being retyped. `Reworded` is the near-miss.
const
  Exit = "Is this payout an attempt to move money out before the account is " &
         "abandoned or closed?"
  Reworded = "Is this payout suspicious?"

let ExitCriteria = %*{
  "true":  "A large amount, to a destination added recently, from a young " &
           "account, with language about closing or finality",
  "false": "Routine settlement to an established destination"}

# --- what the batch does, with no request at all -----------------------------

# The macro hides its Session, so this part uses the API the macro generates.
# `pending` is the number of questions that would be sent, and it is readable
# before `run()` because dedup is a build-time property, not an answer.
var s = newSession(activeClient(), "payout", %payout)

proc report(label: string, want: int, note = "") =
  ## Asserted as well as printed, so `nimble test` fails if dedup ever stops.
  doAssert s.pending == want,
    label & ": expected " & $want & " question(s), got " & $s.pending
  echo label.alignLeft(40), "-> ", s.pending,
       (if want == 1: " question " else: " questions"), note

discard s.feels("", Exit, criteria = ExitCriteria, atLeast = 0.9)
report("1 site,  same text", 1)

discard s.feels("", Exit, criteria = ExitCriteria, atLeast = 0.6)
discard s.feels("", Exit, criteria = ExitCriteria, atLeast = 0.3)
report("3 sites, same text, 3 thresholds", 1,
       " <- atLeast is not part of the identity")

discard s.feels("", Reworded, criteria = ExitCriteria)
report("4 sites, one reworded", 2, " <- instructions are part of it")

discard s.feels("memo", Exit, criteria = ExitCriteria)
report("5 sites, one on a narrower focus path", 3, " <- so is the focus path")
echo()
echo "Two sites collapse only if every field of the normalized record matches."
echo "Keep repeated question text in a const; a one-word drift is a second"
echo "question, billed and answered separately."
echo()

if getEnv("RECKONIM_LIVE").len == 0:
  echo "RECKONIM_LIVE=1 (with a key) runs the withState form below."
  echo "Nothing above needed either one."
  quit 0

# --- the same thing as you would actually write it ---------------------------

var actions: seq[string]

withState payout:
  # Three rules, written independently, each at the bar its own action earns.
  # With the read below that is four sites; the trace reports one question.
  if payout.feels(Exit, criteria = ExitCriteria, atLeast = 0.9):
    actions.add "freeze the payout and notify the risk desk"

  if payout.feels(Exit, criteria = ExitCriteria, atLeast = 0.6):
    actions.add "hold for manual review before release"

  if payout.feels(Exit, criteria = ExitCriteria, atLeast = 0.3):
    actions.add "attach an audit note to the account"

  # Same answer, not three samples of it. Three separate requests could disagree
  # by enough to straddle a threshold; one answer read three times cannot.
  let p = payout.feels(Exit, criteria = ExitCriteria).probability
  echo "P(exit scam) = ", p.formatFloat(ffDecimal, 2),
       " - one number, read by all three rules"

echo()
echo "actions"
if actions.len == 0:
  echo "  - release"
for a in actions:
  echo "  - ", a
