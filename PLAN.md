# ReckoNim — Plan

A probabilistic judgment layer for Nim over TypeSafe's Jev model.

ReckoNim is not a new language. It is a Nim package: one macro, three judgment
procs, a client, and a record/replay store. Everything else is ordinary Nim.

Its single job is to let judgments be written where they are needed, in-situ, while
the judgments that share a state collapse into one Jev request.

Status: phases 1–4 implemented and verified against the live service. See
[README.md](README.md) for usage; this document is the design record and the
source of truth for why things are the way they are.

---

## 1. The measurement that justifies the project

Live, `jev-1.13.0`, one state, N noul questions per request:

| questions/call | latency | input tokens |
|---|---|---|
| 1  | 0.137s | 327  |
| 5  | 0.166s | 443  |
| 20 | 0.125s | 888  |
| 60 | 0.163s | 2088 |

Latency is flat to at least 60 questions. State costs ~297 tokens once; each question
adds ~30. Sixty judgments batched against sixty issued serially: **9.4x fewer input
tokens, ~52x less wall clock**.

This is the whole value proposition. A programmer writing judgments one at a time,
where each is needed, should not pay 52x for the privilege. ReckoNim's job is to make
the ergonomic form and the efficient form the same form.

Jev's own documentation endorses this directly (`patterns/fan-out.md`): *"Send many
questions in a single call, including speculative ones, and let your code decide what's
relevant."* Speculative evaluation is not a liberty ReckoNim takes; it is the vendor's
recommended pattern.

---

## 2. Verified API facts

All probed against the live service, not inferred from docs.

`POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer <key>`.

```json
{ "state": "string | object | array",
  "model": "jev-latest",
  "questions": { "<id>": { "type": "noul|choice|score",
                           "instructions": "string | object | array",
                           "criteria": "object | list" } } }
```

Response mirrors the keys under `answers`, plus `usage`.

| Fact | Consequence for ReckoNim |
|---|---|
| One `state` per request, N questions, all seeing the same state | The batching unit is the state. §4. |
| Question ids are caller-chosen map keys; `@ . [ ] # :` pass through verbatim | Source identity and wire key are one string. §6. |
| `instructions` accepts objects with `inspect` / `compare` / `focus` | Focus is native to Jev, not a ReckoNim invention. §4. |
| Indexed focus paths discriminate: `messages[0]`→0.01, `[1]`→0.99, `[2]`→0.02 | Loop batching is a later additive change, not a redesign. §11. |
| Bracket beats dot: `messages[1]`→0.99 vs `messages.1`→0.94 | Emit brackets. |
| **A focus path that does not resolve returns no error, and is not ignored** — `inspect` is a hint, not a selector; on a miss the model judges the whole state. A missed path beside a field reading "ENTERPRISE, EXTREMELY HIGH VALUE" returned **0.92** | Unresolvable paths must never be sent. §5a. |
| Request *structure* is strictly validated (score `criteria` as a map → 422 with a field path) | Malformed requests fail loudly; only focus paths fail silently. |
| Identical question under two keys returns identical values | Content-hash dedup is safe. §6. |
| **Answers are isolated from batch composition.** A question whose path misses answers wrongly (0.74) while its sibling is unmoved (0.04 across 5 runs, with and without it). No trend in a borderline answer across batch sizes 1→31 | Dropping, dedup and speculative extras are all semantically invisible — the premise the batching design rests on. |
| **Isolation does not extend to the state.** The row above varies the *questions* against a fixed state. Varying the *records inside* one array state is a different claim and is false: pg-jev measures 1–20 records/request at 100% correct, 40 at 92–98%, 80 at 77–94%, and duckdb-jev #4 measures six tickets scoring 1.19 alone, 1.53 among mild companions, 1.23 among severe ones on a 0–3 rubric — all six moving together | Never pack records into a shared state. Many records means one request each, concurrently: `withEachState`, §32. |
| **The documented request limit does not bind.** `models.md` publishes 1200 requests/minute (20/s). Measured over 200 one-record requests at widths of 4, 8, 16, 32 and 64 in flight: 21, 36, 54, 77 and 133 requests/second, with 0 rescheduled and 0 parked in all 35 `runAll` batches. 64 sustains 6.7x the published rate without a 429 | Do not derive the in-flight width from 1200/min. The token limit is the one that looks real: 64 ran at 134k tokens/s against a documented 250k. §32 |
| Run-to-run noise is ±0.02 on an ambiguous question, 0 on a clear one | Replay reproduces exactly; live re-runs do not. Record anything you assert on. |
| Noul returns only `noul: 0..1` — no confidence field | Boolean coercion is one float compare. §7. |
| Choice returns `choice`, `confidence`, `probabilities` | |
| Score returns `score` (float), `confidence`, `probabilities`, `legend` | |
| **Score is an expected value, not an argmax** — `{0:0.73, 1:0.27, 2:0.0}` yields `score: 0.27` | Never collapse score and most-likely-level. §7. |

Limits (`models.md`): 64k tokens per request, 32k for state plus the longest question;
1200 requests/minute; 250k tokens/second. Pricing $42/Bn input tokens, output free.

---

## 3. Surface syntax

```nim
import reckonim

withState ticket:
  if ticket.message.feels "urgent":
    escalate(ticket)

  if ticket.message.feels("spam", criteria = {
       "true":  "Unsolicited bulk or phishing",
       "false": "Genuine customer contact" }):
    archive(ticket)

  let team = ticket.message.choice({
    "billing":   "Payments, invoicing, refunds, payouts",
    "technical": "Bugs, outages, integrations",
    "sales":     "Pricing, upgrades, new accounts" })

  let anger = ticket.message.score(["Calm", "Frustrated", "Very angry"])

  if team.confidence > 0.9:
    route(team.value)
```

One Jev request. Four questions. `state = ticket`.

`withState X` means literally: **X is the Jev `state`**. Nothing is inferred.

---

## 4. The core rule

> A `withState S` block collects judgments whose receiver is a qualified path rooted
> at `S`. Those judgments share one Jev request with `state = S`. A receiver rooted
> elsewhere belongs to a different state, and therefore a different `withState` and a
> different request.

This is not a heuristic or an optimisation. The API accepts exactly one `state` per
request, so the batching boundary is dictated by the protocol.

```text
withState S
    |
    +-- S.foo.feels(...)
    +-- S.bar.choice(...)
    +-- S.baz.score(...)
             |
             v
       one Jev request, state = S
```

What this deletes, compared to the original design document: the judgment IR graph,
the wave scheduler, the dataflow analyser, and the hoisting analysis. None are replaced.
The focus path's root answers the only question that was ever being asked.

### Dependent judgments are explicit

The original document's §30 example implied an inferred second wave. Under the settled
rule that inference does not exist:

```nim
withState ticket:
  ticket.message.feels "urgent"

let reply = generateReply(ticket)

withState reply:
  reply.feels "appropriate"
```

Two states, two requests, visible in the source. `reply` is not part of `ticket`, so
there is nothing to infer.

### Nested `withState` opens a distinct state

Nesting never augments the outer state:

```nim
withState ticket:
  ticket.message.feels "urgent"
  let reply = makeReply(ticket)
  withState reply:              # distinct state, second request
    reply.feels "appropriate"
```

Combined state is constructed by the programmer, never inferred:

```nim
let review = (ticket: ticket, reply: reply)
withState review:
  review.ticket.message.feels "urgent"
  review.reply.feels "appropriate"
```

### Qualified receivers only (MVP)

`ticket.message.feels(...)`, not bare `message.feels(...)`. Mildly redundant, and it buys:

- focus derivation is a syntactic prefix strip — no macro-time type resolution
- the path is typechecked by Nim as ordinary field access
- refactor safety: rename `message` to `body` and the path updates or fails to compile
- protection against the silent bogus-focus behaviour

Unqualified lexical resolution needs typed-macro machinery. Add it if the qualified form
proves noisy in practice.

---

## 5. Wire mapping

Four concepts, kept separate, each landing somewhere concrete:

```text
state         what Jev sees            -> request `state`
focus         which part it concerns   -> `instructions.inspect` / `.compare`
instructions  the question             -> `instructions.question`
criteria      how to tell outcomes     -> `criteria`
```

```nim
withState ticket:
  ticket.customer.account.plan.feels("high risk to lose", criteria = {
    "true": "Large or long-tenured account", "false": "Small or new account" })
```

becomes

```json
"high_risk@ticket.customer.account.plan#a3f19c2b": {
  "type": "noul",
  "instructions": { "inspect": "customer.account.plan",
                    "question": "high risk to lose" },
  "criteria": { "true": "Large or long-tenured account",
                "false": "Small or new account" } }
```

Focus paths use bracket notation for indices (`messages[2]`), measured to discriminate
better than dots. An empty focus path — `withState reply:` where `reply` is a bare
string and the receiver is the root — emits no `inspect` key.

`criteria` is first-class from day one. `feels "urgent"` is demo shorthand; per
`primitives/noul.md`, criteria are where question quality lives. Score `criteria` is
an ordered list; noul and choice take maps.

## 5a. Unresolvable focus paths

The focus path is derived from Nim syntax, but whether it resolves depends on the
runtime shape of the serialized snapshot. The compile-time check proves the Nim
expression typechecks; it says nothing about the JSON. Measured failure modes that
all typecheck:

| Cause | Example |
|---|---|
| index out of range | `ticket.items[0]` on an empty `seq` |
| nil ref serialized to null | `ticket.customer.account.plan`, `customer` is `nil` |
| missing key | object variant field in an inactive branch |
| not an object | `ticket.message.sub` |
| bracket on an object | `ticket.meta["region"]` — Jev writes object fields dotted |

None of these produce an error from Jev, and none produce a safe "don't know".
`inspect` is a hint: when it misses, the model judges the whole state and answers
confidently about the wrong subject. Nothing in the response distinguishes that
from a correct answer, so thresholds and confidence give no protection.

**`Batch.add` resolves every focus path against the snapshot before sending.**
The snapshot is in hand at block entry and the path is a string, so this is a
walk over in-memory data — one per question, no round trip.

It validates **what actually ships** — the `inspect` and `compare` values inside
`instructions` — not just `QuestionSite.focusPath`, which is ReckoNim's own
bookkeeping. Checking only the bookkeeping field leaves hand-built structured
instructions unguarded, since the two can diverge. `compare` entries are accepted
in either convention: the docs write them root-prefixed (`ticket.sender.email`)
while `inspect` is state-relative, and measured, the service takes both.

Not covered, and inherently not coverable: a reference embedded in prose
instructions, or in a caller-invented key that is not `inspect`/`compare`. A path
that resolves to a semantically useless value (an empty string) is allowed through
deliberately — that is a real answer about real data, not a missed path.

### Prose references are not references

A backticked name in a plain-string instruction resolves against nothing. Measured,
asking ``"Is `food` a sandwich?"``:

| state | `` `missing-page` `` | `` `food` `` |
|---|---|---|
| `{"food": "a BLT on rye"}` | 0.48 | 0.99 |
| `{"food": "a bowl of soup"}` | 0.04 | 0.01 |
| `{"food": "soup", "note": "a club sandwich"}` | 0.25 | 0.02 |
| `{"lunch": "a BLT on rye"}` — no `food` key | 0.37 | **0.98** |

The last row is the point: with no `food` field at all, `` `food` `` returns 0.98,
having read the sandwich out of `lunch`. A reference that has silently stopped
matching the data is indistinguishable from one that works. This is the refactor
rot that state-relative focus paths exist to prevent, and it cannot be seen from
outside the string.

ReckoNim's own API cannot produce it — `feels`/`choice`/`score` always emit
`{"inspect": path, "question": text}`, so backticks a caller writes land in
`question` beside a validated `inspect`. It is reachable only by handing
`QuestionSite` a plain-string `instructions`.

Deliberately **not** mitigated by scanning prose for backticked tokens:
`advanced.md` uses backticks for sibling keys *within the instructions object*
(``"Does `extracted_value` match the `field`?"``), not for state paths, so
treating them as paths would reject the documented pattern. Structured `inspect`
is the only referencing form that can be checked — which is most of why it is the
form the macro emits.

On a miss the question is **dropped from the request and recorded**, not raised:

- Raising at send time would make speculative evaluation observable — a judgment
  in a branch the program never reaches would kill an otherwise-fine run, which
  §7 forbids.
- Reading a dropped judgment raises `UnresolvablePathError` naming the cause and
  the source line. An unreached site stays harmless; a reached one fails loudly.
- Note that `if j:` *is* a read, through the converter.

This reuses the phase-2 unresolved-handle discipline for a second cause. Side
effects: doomed questions stop costing tokens, and a batch whose judgments all
miss skips the request entirely rather than erroring.

`examples/hazard.nim` demonstrates it against the live service.

Worth filing with TypeSafe: erroring on an unresolvable `inspect` would be cheap
for them and the current behaviour is a footgun for every SDK, not just this one.
The local check is still wanted regardless — it catches the problem without a
round trip.

### Compiler requirement

The macro replaces each judgment expression with a batch-result lookup, which would
otherwise discard the receiver expression and skip typechecking it. **Typechecking of
the receiver path must be preserved.** This is the requirement that makes focus paths
refactor-safe and that catches the failure Jev does not report. The generated idiom is
an implementation decision — `static: discard typeof(...)` is one candidate, not a mandate.

---

## 6. QuestionSite and identity

A normalized record, not a graph:

```text
QuestionSite
  id              slug + hash8; doubles as the Jev question key
  stateRoot       identifier of the withState subject
  focusPath       state-relative, brackets for indices, empty when receiver is the root
  primitive       noul | choice | score
  instructions    string or structured object
  criteria        primitive-specific descriptor
  sourceLocation  diagnostics only; excluded from id
```

Identity:

```text
urgent@ticket.message#a3f19c2b
```

`hash8` covers the normalized site **excluding `sourceLocation`**, so unrelated edits
that move line numbers do not invalidate recordings. Source location is retained for
diagnostics.

Two textually identical judgments therefore collide — deliberately. Measured: the same
question under two keys returns identical values, so collapsing duplicates is sound.

```nim
if ticket.message.feels "urgent": a()
if ticket.message.feels "urgent": b()   # one question on the wire, both sites read it
```

This is the dedup, not a bug. Do not "fix" it later by salting with line numbers.

---

## 7. Result types and thresholds

```nim
Judgment[T] = object
  value: T
  site: QuestionSite
  raw: JsonNode          # the answer as returned, for provenance
```

| Primitive | Nim call | `Judgment[T]` | Accessors |
|---|---|---|---|
| noul | `feels(q, criteria = ...)` | `Judgment[bool]` | `.probability` |
| choice | `choice({...})` | `Judgment[string]` | `.confidence`, `.probabilities` |
| score | `score([...])` | `Judgment[float]` | `.confidence`, `.probabilities`, `.legend`, `.level` |

`converter toBool(j: Judgment[bool]): bool` makes `if ticket.message.feels "urgent":`
compile while `.probability` stays reachable. This answers the original document's §31
question with a native Nim feature rather than compiler rewriting, and a failed judgment
raises inside the converter — satisfying "a failed judgment must not silently coerce to
false" for free.

Default threshold 0.5, the neutral point for a noul (0.5 means yes and no are equally
likely — it does not mean "moderately confident"). Per-site override:
`feels("urgent", atLeast = 0.9)`.

Three distinctions the implementation must not collapse:

1. **Noul probability is not confidence.** Noul carries no confidence field. Only choice
   and score do.
2. **Score is not argmax.** `score` is the probability-weighted mean of level indices.
   Measured: `{0:0.73, 1:0.27, 2:0.0}` returns `score: 0.27`. Expose `.score` (expected
   value) and `.level` (most likely) as separate accessors; never derive one by rounding
   the other.
3. **Choice value is not confidence-gated.** `.value` is the selected option regardless of
   how flat the distribution is. Gating is the caller's decision, at a threshold matched
   to the consequence — per `confidence.md`, *"a confidence threshold is not one number."*

`choice` returns `string` in the MVP. Enum generation is sugar; add it when the string
form is demonstrably annoying.

---

## 8. Record and replay

One mechanism, keyed on `hash(state, questions, model)`. A table plus a JSON file, driven
by two environment variables:

```
RECKONIM_RECORD=run.json    append every request/response pair
RECKONIM_REPLAY=run.json    serve matching requests from the file, never contact Jev
RECKONIM_TRACE=1            print batch composition to stderr
```

Because identity excludes source location, a recording survives unrelated edits to the
file it came from. A replay miss is an error, not a silent passthrough.

Persistent semantic caching is a separate, later concern. Record/replay covers
deterministic debugging, regression tests, model-version comparison, and cost control.

Trace output names what batched and why:

```
withState ticket -> 1 request, 4 questions (2 noul, 1 choice, 1 score)
withState reply  -> 1 request, 1 question
  deduped: urgent@ticket.message#a3f19c2b (2 sites)
```

---

## 9. Limits and errors

Enforce the real service constraints; do not invent a billing abstraction. At $42/Bn
input tokens with free output, money is not the binding limit — request size and request
rate are.

- 64k tokens per request, 32k for state plus the longest question: check before sending,
  fail with a message naming the state and the offending question.
- 1200 requests/minute: the runtime owns backoff and retry.
- Distinguish, and never collapse into `false`: program error, transport failure, service
  failure, malformed response, timeout, rate limit, state serialization failure, replay miss.

Diagnostics refer to ReckoNim source locations, never to generated code.

---

## 10. Files

```
flake.nix .envrc            done, verified: nim 2.2.12, `nim c -d:ssl` does real HTTPS
reckonim.nimble             package metadata; stdlib only, no dependencies
src/reckonim.nim            public re-export
src/reckonim/jev.nim        client, request/response types, errors, limits, record/replay
src/reckonim/judge.nim      Judgment[T], converter, feels / choice / score
src/reckonim/withstate.nim  the macro: prefix strip, collection, dedup, batch, trace
tests/                      against a stub transport, plus one live test behind an env guard
examples/triage.nim         the ticket program from §3
```

No dependencies beyond `std/json`, `std/httpclient`, `std/tables`, `std/hashes`,
`std/macros`. Nothing here needs more.

---

## 11. Phases

1. **Client.** `jev.nim`, `QuestionSite`, identity hashing, record/replay, stub transport,
   limit checks. No macro. Verifiable against the live key and useful standalone.
2. **Judgments.** `Judgment[T]`, the converter, thresholds, all three primitive result
   types with the three non-collapsible distinctions from §7.
3. **Macro.** `withState`: prefix strip, collection, dedup, batch, trace, and the receiver
   typechecking requirement from §5.
4. **Examples and README**, including the §1 measurement table.

---

## 12. Deferred, with triggers

| Deferred | Add when |
|---|---|
| Loop batching — splitting a loop into build-questions-then-run-body | A real program loops over a state-rooted collection. Indexed focus paths already work, so this is a pure macro addition with no protocol, identity, or record-format change. Until then a loop emits one request per iteration, correctly, and the trace says so. |
| Unqualified receivers (`message.feels` for `ticket.message`) | The qualified form proves noisy in practice. Needs typed-macro resolution. |
| Enum-typed `choice` results | The string form proves annoying. |
| Persistent semantic cache | Record/replay proves insufficient. |
| Browser playground and its hostile-code sandbox | Someone other than the author needs to run code. The sandbox is a larger project than the language; `nim c -r examples/triage.nim` with `RECKONIM_TRACE=1` demonstrates the idea today. |
| Pluggable evaluators behind an interface | A second evaluator exists. Until then, hardcode Jev. |
| Custom file extension, LSP, package repository | Never, unless something specific demands them. |

---

## 13. Corrections to the original design document

Recorded so the source document can be amended.

1. **§7, speculative evaluation** — vendor-endorsed, not a liberty. Cite
   `patterns/fan-out.md` and the §1 measurements.
2. **§12, thresholds** — noul carries no confidence field. The most-likely-class versus
   probability-above-threshold distinction applies to choice and score only. But it does
   apply, sharply: see the score-is-not-argmax measurement.
3. **§16 step 3, stable judgment IDs** — not a mechanism to design. `questions` is a named
   map and the caller picks the keys. The contribution is choosing keys that survive edits.
4. **§18, the judgment IR** — deleted as a graph, retained as the flat `QuestionSite`
   record in §6.
5. **§19, the wave scheduler** — deleted. The batching boundary is the state, which the
   protocol dictates.
6. **§10, loops** — downgraded from open design risk to a known-easy additive follow-up,
   because indexed focus paths are measured to work.
7. **§13, multi-class** — no longer deferred. All three primitives share one envelope and
   one batching path; omitting score or choice creates more asymmetry than it saves.
8. **§15, state snapshot** — needs no mechanism. `%*state` at block entry; the type must be
   JSON-serializable.
9. **§21 and §23, caching and budgets** — the monetary budget subsystem is unnecessary.
   Enforce the real limits in §9.
10. **§31, judgment result API** — answered by a Nim converter. No compiler rewriting.
11. **§31, receiver semantics** — the receiver is a state-relative focus expression, not an
    alternate state selector. Jev takes focus natively.
12. **§26 and §28, playground and sandbox** — removed from the MVP entirely.
