# A labelled corpus

Every other example in this repository shows that ReckoNim is cheap. This one
is the only one that says how often the answers are **right**, because the rows
carry labels nobody here wrote.

```sh
nim c -d:ssl --path:../../src -r corpus.nim
```

No API key needed: it replays `test.replay.json`, a recording of the live run
the numbers below came from.

## What happened, in plain English

200 real car-complaint reports went in, and the answers were checked against the
official records.

**It is good at reading.** Asked "did a crash happen?", it never once said yes
when the record said no. It just misses some: at a strict setting it catches 45%
of them, at a loose setting 91%.

**The threshold knob does what the docs promise.** Asked "was anyone hurt?",
being loose catches nearly everyone but a third of those are false alarms. Being
strict means no false alarms at all, but 70% of the real ones are missed. Which
you want depends on what happens next.

**Letting it say "not sure" works.** Sorting complaints into 8 categories, it is
right 86% of the time. Skip the quarter it is least sure about and the rest are
right 93% of the time.

**One thing the docs warn about does not matter here.** There is a rule against
averaging severity levels instead of taking the most likely one. On these 200
rows, doing it the wrong way changed the answer exactly once. The rule is still
right; it just costs nothing on easy data.

**Batching is worth it.** The whole run was 200 requests and 34 seconds. Asking
the same questions one at a time would be 5x the requests and 3x the tokens, for
identical answers.

The whole thing costs under a cent.

## The corpus

NHTSA Office of Defects Investigation consumer complaints, pulled from
`https://api.nhtsa.gov/complaints/complaintsByVehicle`. A US government work, so
public domain, and NHTSA redacts personal information before publishing.

Each record has a free-text `summary` written by the complainant and several
structured fields filled in separately — crash, fire, injuries, deaths, and the
vehicle system at fault. The narrative is the state; the structured fields are
the ground truth. Neither can see the other.

`fetch.nim` rebuilds the partition. You should not need to run it.

| | rows | crash | fire | injured |
|---|---|---|---|---|
| `test.json` | 200 | 100 | 2 | 40 |
| `dev.json` | 60 | 30 | 0 | 16 |

Filters, all deliberate, all of which move the reported numbers:

- **Single-system complaints only.** NHTSA lets a complaint name several
  systems. "Which system failed?" has no single right answer for those rows, so
  they are dropped rather than scored against an arbitrary first entry. The
  component accuracy below is therefore on the easier half of the taxonomy.
- **Eight systems, not the whole taxonomy.** `UNKNOWN OR OTHER` is not a system.
- **Crash is stratified 50/50.** Its natural rate is about 4%, at which no
  threshold sweep can tell 0.5 from 0.95. The precision column below is
  therefore *not* the precision you would see in production, where the
  prevalence is far lower. Recall and the shape of the curve carry over; the
  precision column does not.
- **Narratives between 250 and 6000 characters.** The p99 of the pool is around
  2000, so nothing is truncated — which answers the question of whether the
  32k state-plus-question limit binds here. It does not, by an order of
  magnitude.
- **Fire is reported and not scored.** Two positives in 200 is not a
  measurement. It is left in because a realistic intake form asks, and because
  "we cannot measure this" is a result too.

## dev and test

Nothing is trained here, so the split exists for exactly one reason: the
criteria strings were written against `dev.json`, and every number reported
comes from `test.json`. Reusing rows across the two is the only way to cheat at
this and it is easy to do by accident — four rows were read by hand while the
question wording was being settled, and they are listed in `fetch.nim` as
`Burned` so they can never land in the test split.

## What the run measures

**Five judgments per complaint, one request.** Three nouls (crash, fire,
injured), one choice over eight systems, one score over three ordered severity
levels.

**One `withEachState` block for all 200.** The complaints are independent, so
each is its own state and its own request, and the requests go out together
rather than one after another. They are never packed into a shared state: an
answer moves with whatever is packed beside it, and measuring answers is the
entire point of this example.

The output has four sections:

1. **Noul threshold sweeps.** True/false positives and negatives at seven
   values of `atLeast`, with precision, recall and F1. This is the evidence for
   "pick the threshold from the consequence": 0.5 and 0.95 are different
   operating points, not different amounts of care.
2. **Choice coverage against accuracy.** Abstain below a confidence bar, sweep
   the bar. Accuracy on the answered rows should rise as coverage falls. That is
   the confidence-gating advice in `usage-rules.md`, measured rather than
   asserted.
3. **Score against an ordinal label.** MAE for `.level` (argmax), for `.value`
   (weighted mean), and for `round(.value)` — the thing `usage-rules.md` tells
   you never to write.
4. **Cost, measured.** The whole run, then the first 20 rows asked twice: five
   questions in one request, and one question per request. Both halves use
   `withEachState`, so the requests are in flight the same way in both and the
   only difference left is how many questions each request carries. Both re-ask
   the same question and criteria strings, so the token counts are comparable.

## The numbers

From the recorded test run. Replay is instant, so the seconds the program prints
under replay are not the live ones.

Both live wall-clocks below are measured. The 200 requests took **33.6s** when
they went out one after another, and **3.4s** through one `withEachState` at the
default of sixteen in flight — **9.9x**, for the same 200 requests carrying the
same 1000 questions. Concurrency changes when the requests leave, not what is in
them: the token counts are identical.

This corpus is also where that default was set. The same 200 requests, at five
widths, on the live service:

| in flight | 200 requests | each second | rescheduled | failed |
|---|---|---|---|---|
| 4 | 9.5s | 21 | 0 | 0 |
| 8 | 5.5s | 36 | 0 | 0 |
| 16 | 3.7s | 54 | 0 | 0 |
| 32 | 2.6s | 77 | 0 | 0 |
| 64 | 1.5s | 133 | 0 | 0 |

Nothing was refused at any width, so the documented 1200 requests each minute —
20 each second — is not enforced at that value. The reasons for stopping at
sixteen are in the main [README](../../README.md#limits-and-errors). Component
accuracy was 85.0% at every width except one run at 84.5%, which is one row of
the ordinary run-to-run drift, so the width does not touch the answers.

**crash** — 100 positive of 200. Precision is 100% at every threshold; what
moves is recall.

| `atLeast` | precision | recall |
|---|---|---|
| 0.10 | 100.0% | 91.0% |
| 0.50 | 100.0% | 85.0% |
| 0.90 | 100.0% | 72.0% |
| 0.95 | 100.0% | 45.0% |
| 0.99 | — | 0.0% |

**injured** — 40 positive of 200. Here both move, which is what a threshold is
for.

| `atLeast` | precision | recall |
|---|---|---|
| 0.10 | 60.7% | 92.5% |
| 0.50 | 83.8% | 77.5% |
| 0.95 | 93.3% | 70.0% |
| 0.99 | 100.0% | 30.0% |

**component** — choice over eight systems. Accuracy climbs as coverage falls,
monotonically except for one dip.

| abstain below | coverage | accuracy on answered |
|---|---|---|
| 0.00 | 100.0% | 85.5% |
| 0.70 | 92.5% | 88.1% |
| 0.90 | 87.5% | 89.1% |
| 0.99 | 74.5% | 92.6% |

**severity** — MAE 0.12 for `.level`, 0.13 for `.value`, 0.13 for
`round(.value)`. `.level` and `round(.value)` disagree on **1 row of 200**.

That last number is worth stating plainly rather than dressing up: on this
corpus the `.level` versus `round(.value)` distinction is nearly invisible,
because the answers are mostly confident and unimodal. It bites when they are
not — `examples/incident.nim` is a recorded case where the mean lands on a level
holding 7% of the mass. The rule is still right; this corpus is just not where
it is expensive to break it.

**cost** — 200 requests, 1000 questions, 200,863 input tokens. 3.4s through
`withEachState`; 33.6s when the same requests went out sequentially.

The first 20 rows asked one question per request: 100 requests, 60,810 input
tokens, 2.4s. The same rows with five questions per request: 20 requests, 20,722
input tokens, 0.6s. **5.00x the requests, 2.93x the input tokens, 4.0x the
time.** Both halves run through `withEachState`, so that time ratio is the cost
of the extra requests alone, not of sending them sequentially. The extra input is
one copy of the narrative per question; the questions and the answers are
identical either way.

At the published $42/Bn input tokens, the whole 200-row batched run costs about
$0.0084. Unbatched it would be about $0.025. The reason to batch is the request
count and the latency, not the bill.

## What this does not show

- **Accuracy on the natural distribution.** Crash is stratified to 50/50.
- **Accuracy on ambiguous complaints.** Multi-system rows are excluded.
- **Whether the labels are right.** They are consumer-filled checkboxes. Some
  narratives describe a collision while the crash box is empty, and those count
  against the model here.
- **Run-to-run stability.** Two live runs, which is not a stability study. They
  agree everywhere except one severity row, which moved from level 1 to level 2
  against a label of 1. Every threshold sweep, coverage curve and MAE was
  unchanged. That is what PLAN.md's ±0.02 of noise on an ambiguous question
  predicts: enough to move a row across a threshold, not enough to move a curve.
  It is also why the reported numbers come from a recording and not from
  whatever the service says today.
