## 200 labelled complaints, five judgments each, scored against ground truth.
##
## One `withEachState` block: 200 independent records, one request each, several
## in flight. Never one request holding all 200 - see the README.
##
## Every other example in this repo shows that ReckoNim is cheap. This one is
## the only one that can say how often the answers are *right*, because the
## corpus carries labels that nobody in this repo wrote.
##
##   nim c -d:ssl --path:../../src -r corpus.nim
##
## Replays a committed recording by default, so it needs no API key and prints
## the numbers this file documents. Against the live service:
##
##   RECKONIM_LIVE=1 ./corpus            # test split - the reported numbers
##   RECKONIM_LIVE=1 ./corpus --dev      # dev split - for tuning the criteria
##
## Re-record after changing any question or criteria string, because changing
## them changes the request and the recording is keyed on the request:
##
##   RECKONIM_LIVE=1 RECKONIM_RECORD=test.replay.json ./corpus
##
## The dev/test split is the whole reason there are two files. Criteria strings
## were written and revised against dev.json. Every number below comes from
## test.json, which was not looked at while they were being written.

import std/[json, math, os, sequtils, strutils, tables, times]
import reckonim

const
  here = currentSourcePath().parentDir
  Unbatched = 20  ## rows re-run one-question-per-request, to measure the batch

let dev = "--dev" in commandLineParams()
let rowsFile = here / (if dev: "dev.json" else: "test.json")
let recording = here / (if dev: "dev.replay.json" else: "test.replay.json")

if getEnv("RECKONIM_LIVE").len == 0 and getEnv("RECKONIM_RECORD").len == 0:
  # Only the test run is committed as a recording - it is the one whose numbers
  # are reported. The dev split is for tuning, which is a live activity.
  if fileExists(recording):
    putEnv("RECKONIM_REPLAY", recording)
  else:
    echo "no recording for ", rowsFile.extractFilename,
         " - run it live:  RECKONIM_LIVE=1 ./corpus", (if dev: " --dev" else: "")
    quit 1

type Complaint = object
  vehicle: string
  narrative: string

let Components = %*{
  "air bags":         "Air bags, seat belts or other occupant restraints",
  "service brakes":   "Braking: pedal, ABS, calipers, lines, stopping distance",
  "steering":         "Steering: wheel, column, rack, power steering, alignment",
  "power train":      "Transmission, driveline, clutch, gear selection, rolling away",
  "electrical system": "Battery, wiring, charging, displays, stalling from electrical fault",
  "engine":           "Engine internals, oil, cooling, misfires, loss of power",
  "vehicle speed control": "Throttle, cruise control, acceleration the driver did not ask for",
  "forward collision avoidance": "Automatic emergency braking, collision warning, and their false activations"}

let Severity = %*[
  "A malfunction, but no crash, no fire and nobody hurt",
  "A crash or a fire happened, and nobody was hurt",
  "Someone was injured or killed"]

# The five questions, named once. The unbatched cost comparison at the bottom
# re-asks these exact strings; a paraphrase there would make the token counts
# incomparable.
const
  QCrash = "Did a collision actually happen?"
  QFire = "Did any part of the vehicle catch fire, smoke, melt or burn?"
  QInjured = "Was anyone physically hurt?"
  QComponent = "Which vehicle system failed?"
  QSeverity = "How bad was the outcome for the people involved?"

let
  CCrash = %*{
    "true": "The vehicle struck, or was struck by, another vehicle, a person or an object",
    "false": "A malfunction is described, but nothing was struck"}
  CFire = %*{
    "true": "Fire, flames, smoke, burning or melting on the vehicle",
    "false": "No fire, smoke or burning is described"}
  CInjured = %*{
    "true": "Someone was injured, treated, hospitalised or killed",
    "false": "Nobody was hurt, or no injury is mentioned"}

type Row = object
  crashP, fireP, injP, compConf, sevValue: float
  comp: string
  sevLevel: int
  labCrash, labFire, labInj: bool
  labComp: string
  labSev: int

proc labelSeverity(r: JsonNode): int =
  if r["injured"].getBool or r["killed"].getBool: 2
  elif r["crash"].getBool or r["fire"].getBool: 1
  else: 0

# ---------------------------------------------------------------- the run

let corpus = parseJson(readFile(rowsFile))
let sampleRows = min(Unbatched, corpus.len)

# The complaints are the states. The label columns stay behind in `corpus`,
# where the model cannot see them.
var complaints: seq[Complaint]
for r in corpus:
  complaints.add Complaint(vehicle: r["vehicle"].getStr,
                           narrative: r["narrative"].getStr)

var results: seq[Row]
var labelled = 0
let started = epochTime()

# 200 independent records, so one `withEachState` rather than 200 `withState`
# blocks in a loop. Each complaint is still its own state carrying its own five
# questions in one request - what changes is that the requests leave together
# instead of one after another.
#
# The records are deliberately *not* packed into one state. An answer moves with
# whatever is packed beside it, and this file exists to measure answers.
withEachState c in complaints:
  let crash = c.narrative.feels(QCrash, criteria = CCrash)
  let fire = c.narrative.feels(QFire, criteria = CFire)
  let injured = c.narrative.feels(QInjured, criteria = CInjured)
  let comp = c.narrative.choice(QComponent, Components)
  let sev = c.narrative.score(QSeverity, Severity)

  # The bodies run one at a time, in order, on this thread, so a plain counter
  # walks the label rows in step with the complaints.
  let r = corpus[labelled]
  inc labelled

  results.add Row(
    crashP: crash.probability, fireP: fire.probability, injP: injured.probability,
    comp: comp.value, compConf: comp.confidence,
    sevLevel: sev.level, sevValue: sev.value,
    labCrash: r["crash"].getBool, labFire: r["fire"].getBool,
    labInj: r["injured"].getBool, labComp: r["component"].getStr,
    labSev: labelSeverity(r))

let batchedSeconds = epochTime() - started
let batched = (requests: activeClient().requests,
               questions: activeClient().questionsAsked,
               inTok: activeClient().inputTokens,
               outTok: activeClient().outputTokens)

# ---------------------------------------------------------------- reporting

proc pct(x: float): string = (x * 100).formatFloat(ffDecimal, 1) & "%"
proc f2(x: float): string = x.formatFloat(ffDecimal, 2)

echo "corpus: ", rowsFile.extractFilename, ", ", results.len, " complaints"
echo "labels: crash ", results.countIt(it.labCrash), ", fire ",
     results.countIt(it.labFire), ", injured ", results.countIt(it.labInj),
     " (NHTSA checkbox fields, filled in by the complainant)"
echo()

# --- noul: the threshold is an operating point, not a detail -----------------

proc sweep(name: string, got: proc (r: Row): float, lab: proc (r: Row): bool) =
  let positives = results.countIt(lab(it))
  echo name, "  (", positives, " positive of ", results.len, ")"
  if positives < 10:
    echo "  too few positives to measure; reported for honesty, not as a result"
    echo()
    return
  echo "  atLeast   TP   FP   FN   TN   precision   recall      F1"
  for t in [0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99]:
    var tp, fp, fn, tn = 0
    for r in results:
      let yes = got(r) >= t
      if yes and lab(r): inc tp
      elif yes: inc fp
      elif lab(r): inc fn
      else: inc tn
    let
      prec = if tp + fp > 0: tp / (tp + fp) else: 0.0
      rec = if tp + fn > 0: tp / (tp + fn) else: 0.0
      f1 = if prec + rec > 0: 2 * prec * rec / (prec + rec) else: 0.0
    echo "  ", f2(t).align(7), ($tp).align(5), ($fp).align(5), ($fn).align(5),
         ($tn).align(5), pct(prec).align(12), pct(rec).align(9), pct(f1).align(8)
  echo()

sweep("crash", proc (r: Row): float = r.crashP, proc (r: Row): bool = r.labCrash)
sweep("fire", proc (r: Row): float = r.fireP, proc (r: Row): bool = r.labFire)
sweep("injured", proc (r: Row): float = r.injP, proc (r: Row): bool = r.labInj)

# --- choice: abstaining below a confidence bar buys accuracy -----------------

echo "component (choice over ", Components.len, " systems)"
echo "  abstain below   answered   coverage   accuracy on answered"
for t in [0.0, 0.5, 0.7, 0.8, 0.9, 0.95, 0.99]:
  let answered = results.filterIt(it.compConf >= t)
  if answered.len == 0: continue
  let correct = answered.countIt(it.comp == it.labComp)
  echo "  ", f2(t).align(13), ($answered.len).align(11),
       pct(answered.len / results.len).align(11),
       pct(correct / answered.len).align(23)
echo()

# --- score: .level and .value are different numbers --------------------------

echo "severity (score over 3 ordered levels)"
var maeLevel, maeValue = 0.0
for r in results:
  maeLevel += abs(float(r.sevLevel - r.labSev))
  maeValue += abs(r.sevValue - float(r.labSev))
echo "  MAE of .level (argmax)         ", f2(maeLevel / float(results.len))
echo "  MAE of .value (weighted mean)  ", f2(maeValue / float(results.len))
echo "  MAE of round(.value)           ", f2(results.foldl(
       a + abs(float(int(b.sevValue + 0.5) - b.labSev)), 0.0) / float(results.len))
echo()
echo "  confusion, .level down, label across"
echo "         0     1     2"
for got in 0 .. 2:
  var line = "     " & $got
  for want in 0 .. 2:
    line.add ($results.countIt(it.sevLevel == got and it.labSev == want)).align(6)
  echo line

let disagree = results.countIt(int(it.sevValue + 0.5) != it.sevLevel)
echo "  round(.value) disagrees with .level on ", disagree, " of ", results.len,
     " rows"
echo()

# --- cost: the batch, measured against the same rows unbatched ---------------

let replaying = getEnv("RECKONIM_REPLAY").len > 0
echo "cost"
echo "  batched     ", batched.requests, " requests, ", batched.questions,
     " questions, ", batched.inTok, " in / ", batched.outTok, " out, ",
     batchedSeconds.formatFloat(ffDecimal, 1), "s"
if replaying:
  echo "              (replayed: the token counts are the live ones, the seconds are not)"

# The first `Unbatched` rows, asked twice: five questions in one request, then
# one question per request. Both use `withEachState`, so the requests are in
# flight the same way in both and the only difference left is how many questions
# each request carries. Both re-ask the exact strings above, so the token counts
# are comparable - live, this costs the sample rows a second time.
let sample = complaints[0 ..< sampleRows]

var before = (requests: activeClient().requests, inTok: activeClient().inputTokens)
let batchedStart = epochTime()
withEachState c in sample:
  discard c.narrative.feels(QCrash, criteria = CCrash).probability
  discard c.narrative.feels(QFire, criteria = CFire).probability
  discard c.narrative.feels(QInjured, criteria = CInjured).probability
  discard c.narrative.choice(QComponent, Components).value
  discard c.narrative.score(QSeverity, Severity).level

let sampleBatched = (requests: activeClient().requests - before.requests,
                     inTok: activeClient().inputTokens - before.inTok,
                     secs: epochTime() - batchedStart)

# Five blocks, one question each, so every block ships the whole narrative again.
before = (requests: activeClient().requests, inTok: activeClient().inputTokens)
let unbatchedStart = epochTime()
withEachState c in sample:
  discard c.narrative.feels(QCrash, criteria = CCrash).probability
withEachState c in sample:
  discard c.narrative.feels(QFire, criteria = CFire).probability
withEachState c in sample:
  discard c.narrative.feels(QInjured, criteria = CInjured).probability
withEachState c in sample:
  discard c.narrative.choice(QComponent, Components).value
withEachState c in sample:
  discard c.narrative.score(QSeverity, Severity).level

let unbatched = (requests: activeClient().requests - before.requests,
                 inTok: activeClient().inputTokens - before.inTok,
                 secs: epochTime() - unbatchedStart)
echo "  first ", sampleRows, " rows, one question per request:"
echo "              ", unbatched.requests, " requests, ", unbatched.inTok,
     " in, ", unbatched.secs.formatFloat(ffDecimal, 1), "s"
echo "  the same ", sampleRows, " rows, five questions per request:"
echo "              ", sampleBatched.requests, " requests, ", sampleBatched.inTok,
     " in, ", sampleBatched.secs.formatFloat(ffDecimal, 1), "s"
echo "  ratio       ", f2(unbatched.requests / sampleBatched.requests),
     "x the requests, ", f2(unbatched.inTok / sampleBatched.inTok),
     "x the input tokens"
echo()
echo "The gap is one copy of the narrative per question. Nothing else changed:"
echo "the questions are the same questions and the answers are the same answers."
