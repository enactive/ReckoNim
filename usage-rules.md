# ReckoNim usage rules

Rules for writing a Nim program that uses ReckoNim. Written for a coding agent.

Copy this file into the project that depends on ReckoNim, or append it to that
project's `AGENTS.md`. It describes calling ReckoNim, not changing it.

For what ReckoNim is and why, read `README.md`. This file is only rules.

## The model in four sentences

A **question** is one line of Nim that asks Jev about your data. The **state** is
the value Jev sees; `withState ticket:` means `ticket` is the state. The **focus
path** is the receiver with the state root stripped, so
`ticket.customer.account.plan.feels(...)` sends `inspect: customer.account.plan`.
Every question in one `withState` block goes to Jev in one request, before any of
the block's code runs.

## Hard rules

These three stop the build. The error text is quoted so you can recognize it.

**1. The receiver must start at the state root.**

```nim
withState ticket:
  ticket.message.feels "..."     # yes
  message.feels "..."            # no: unqualified
  reply.feels "..."              # no: "is not rooted at state `ticket`"
```

A value that is not part of the state needs its own block and its own request.

**2. `withState` takes a plain identifier.**

```nim
withState (a: ticket, b: reply):      # no: "needs a plain identifier"

let review = (ticket: ticket, reply: reply)   # yes: bind first
withState review:
  review.ticket.message.feels "..."
  review.reply.feels "..."
```

A judgment rooted at the tuple itself (`review.feels "..."`) sends no `inspect`
key, so Jev reads both values - that is the case the tuple exists for.
`examples/review.nim` judges a diff against its commit message that way.

**3. The focus path must typecheck.**

```nim
ticket.account.nonexistentField.feels "..."
# error: focus path `account.nonexistentField` does not resolve in state `ticket`
```

This check exists because Jev does not report a path that points at nothing. It
answers confidently about the whole state instead. Never route around the check
by moving a path into a string.

## The three primitives

```nim
withState ticket:
  # noul -> Judgment[bool], accessors .probability .atLeast(x)
  let urgent = ticket.message.feels("Is this time-sensitive?")

  let spam = ticket.message.feels("Is this spam?",
    criteria = %*{"true":  "Unsolicited bulk or phishing",
                  "false": "Genuine customer contact"},
    atLeast = 0.9)

  # choice -> Judgment[string], accessors .value .confidence .probabilities
  let team = ticket.message.choice("Which team should handle this?",
    %*{"billing":   "Payments, invoicing, refunds",
       "technical": "Bugs, outages, integrations",
       "sales":     "Pricing, upgrades, renewals"})

  # score -> Judgment[float], accessors .value .level .confidence .legend
  let anger = ticket.message.score("How frustrated is the customer?",
    %*["Calm and matter-of-fact", "Visibly annoyed", "Angry, with a threat"])
```

`criteria` is a JSON object for noul and choice, and an ordered JSON array for
score. Build it with `%*`.

## Reading results

Three distinctions. Collapsing any one produces a confident wrong answer.

| Do not write | Write | Why |
|---|---|---|
| `urgent.confidence` | `urgent.probability` | A noul has no confidence field. This raises. |
| `round(anger.value)` | `anger.level` | `.value` is the probability-weighted mean; `.level` is the argmax. For `{0:0.45, 1:0.1, 2:0.45}` the mean is 1.0, a level with 10% of the mass. `examples/incident.nim` is a recorded live case: `{0:0.38, 1:0.07, 2:0.55}`, mean 1.16, argmax 2. |
| `route(team.value)` | `if team.confidence > 0.8: route(team.value)` | `.value` is the selection however flat the distribution is. Measured on 200 labelled rows (`examples/corpus`): a choice over 8 options is 85.5% accurate at full coverage and 92.6% on the 74.5% of rows where `.confidence >= 0.99`. |

A noul coerces to `bool` through a converter, so `if ticket.message.feels "...":`
works. `if j:` counts as a read.

Pick the threshold from the consequence, not from habit. `atLeast = 0.95` when a
true answer means no human ever sees the item; the 0.5 default when the two
outcomes cost the same. Use `j.atLeast(x)` to gate one action at a different
level without changing the question. `examples/moderation.nim` reads one answer
at three bars; the trace still shows one question.

Measured on 200 labelled complaints (`examples/corpus`), one noul at seven
thresholds: precision 60.7% and recall 92.5% at 0.1, precision 100% and recall
30.0% at 0.99. The threshold is the whole decision about which errors you are
willing to make.

## Keep it to one request

- **Put every question about one value in one `withState` block.** Two blocks
  over the same value are two requests.
- **Do not hoist questions out of branches by hand.** Questions in branches that
  never run are already sent, deliberately: they cost ~30 tokens and no latency.
  Write the question where the answer is used.
- **A question is an expression, not a declaration.** It is legal anywhere an
  expression is: an `if` condition, an operand of `and`, a call argument, or with
  an accessor read straight off it (`ticket.message.score(...).level >= 2`). The
  macro lifts it into the batch from wherever it is written. Use `let` only when
  the same answer is read more than once. `examples/triage.nim` shows both.
- **A nested `withState` is a second request.** For one request over two values,
  build a tuple and use that as the state.
- **Identical questions deduplicate.** Sites with the same state root, focus
  path, primitive, question text and criteria become one question on the wire and
  one answer read many times. This is intended; do not add noise to make them
  distinct, and do not hoist a shared `let` to avoid a duplicate that costs
  nothing. `atLeast` is not part of the identity, so the same question at three
  thresholds is still one question. Rewording it by one word is not — keep
  repeated text in a `const`. `examples/dedup.nim` asserts all of this.
- **Avoid a question inside a loop.** A runtime index makes one request per
  iteration today. Prefer one question whose focus path is the collection, or a
  literal index (`ticket.messages[1]`), which batches normally. `examples/loop.nim`
  runs both forms over one seq; the `RECKONIM_TRACE=1` output is the argument.

## Many records: `withEachState`

For N independent records judged the same way, use `withEachState`, not a loop
of `withState`:

```nim
withEachState ticket in tickets:
  let team = ticket.message.choice("Which team should handle this?", %*{...})
  if ticket.message.feels "Is this time-sensitive?":
    escalate(ticket)
```

Each record is still its own state and its own request, with its own questions
batched into it. What `withEachState` adds is that the requests go out together
instead of one after another.

- **It is not a concurrency control.** There is nothing to tune and no async in
  anything you write. It is you stating that the records are independent and may
  be resolved in any order — which cannot be inferred from a `for` loop, whose
  body may depend on the previous iteration or `break`.
- **The bodies still run one at a time, in order, on your thread.** Appending to
  a seq or printing inside the block needs no locking.
- **Do not put the records in one state to save a request.** An answer moves with
  the records packed beside it: measured, the same ticket scores 1.19 alone and
  1.53 among mild companions on a 0–3 rubric, and per-record accuracy falls from
  100% at 20 records to 77–94% at 80. `withEachState` never does this.
- **A failed record does not stop the others.** Its error is parked and raised
  when one of its judgments is read, naming the original failure. Retryable
  failures get one more attempt automatically. Do not catch and default.
- **`RECKONIM_TRACE=1` prints a `runAll` summary line** with the width used, the
  request count, how many were rescheduled, and how many parked.
- **The width is 16 by default and is tunable.** `RECKONIM_IN_FLIGHT=32` for a
  sweep without recompiling, or `activeClient().inFlight = 32` in the program.
  Below 1 or non-numeric is refused when the client is built. Do not change it
  from arithmetic on the published rate limit — that limit was measured not to
  bind. Change it from a measurement of your own workload, and read the
  `rescheduled` count, not just the clock: a width that is too high shows up
  there and costs more than it saved.

## Do not do these

- **Do not put a state field name in backticked prose.** ``feels "Is `food`
  fresh?"`` is unchecked. It resolves against nothing, reads a neighbouring field
  and answers confidently. Use the receiver to say what you mean:
  `ticket.food.feels "Is this fresh?"`.
- **Do not ask a question that code can answer.** `ticket.total > 1000` is a
  comparison, not a judgment. Questions are for unstructured content: tone,
  intent, category, severity. `examples/rfp.nim` prints both halves of one
  review: five code checks at zero requests, four judgments in one.
- **Do not treat a dropped question as `false`.** If the focus path misses in the
  snapshot at runtime (a nil ref, an empty seq, a missing key), the question is
  not sent, and reading it raises `UnresolvablePathError` naming the cause and
  the line. Fix the data or guard before the block; do not catch and default.
- **Do not mutate the state inside the block and expect the questions to see it.**
  The snapshot is taken at block entry.
- **Do not assert on live answers.** Record, then replay.

## Errors you may see

| Error | Meaning |
|---|---|
| `JevConfigError` | No API key. Set `JEV_API_KEY`, or use replay. |
| `UnresolvedError` | A judgment was read before `run`. Only reachable in the low-level API. |
| `UnresolvablePathError` | The focus path missed in the snapshot, so the question was never asked. |
| `JevLimitError` | Your request exceeds 64k tokens, or 32k for state plus longest question. |
| `ReplayMissError` | `RECKONIM_REPLAY` is set and the file has no matching request. |
| `JevIdCollisionError` | Two different questions hashed to one id. Report it; the fix is a wider hash. |
| `JevServiceError` / `JevTransportError` | The service answered non-2xx, or could not be reached. |

None of them coerce to `false`.

## Testing

Assign a stub transport to `globalClient`. No network, no key, deterministic:

```nim
import std/json
import reckonim

var requests: seq[JsonNode]

globalClient = newClient(apiKey = "x", transport = proc (p: JsonNode): JsonNode =
  requests.add p
  var res = newJObject()
  for qid, q in p["questions"]:
    res[qid] = %*{"type": "noul", "noul": 0.94}
  %*{"model": "jev-1.13.0", "answers": res,
     "usage": {"input_tokens": 400, "output_tokens": 50}})
```

Assert on what reached the wire: `requests.len` for the number of requests,
`requests[0]["questions"].len` for the number of questions,
`q["instructions"]["inspect"]` for the focus path.

Against the real service, record once and replay after:

```sh
RECKONIM_RECORD=run.json ./yourprogram    # capture
RECKONIM_REPLAY=run.json ./yourprogram    # deterministic, no key needed
RECKONIM_TRACE=1         ./yourprogram    # print the batch to stderr
```

A live answer moves by about 0.02 between runs on an ambiguous question. Anything
you assert on must come from a recording.

## Build

```sh
nim c -d:ssl --path:<reckonim>/src -r yourprogram.nim
```

`-d:ssl` is required; it links against OpenSSL. After `nimble install` from a
ReckoNim checkout, drop `--path`.

## Checklist before you finish

- [ ] Every receiver starts at the state root.
- [ ] One `withState` per value, not one per question.
- [ ] `criteria` given for every question whose answer drives an action.
- [ ] `atLeast` set from the consequence for any asymmetric decision.
- [ ] `choice` results gated on `.confidence`.
- [ ] `.level` used for the most likely band, `.value` for the expected value.
- [ ] No state field names written inside question strings.
- [ ] Tests use a stub transport or a replay file, never the live service.
- [ ] `RECKONIM_TRACE=1` shows the request count you expect.
