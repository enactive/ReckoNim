# ReckoNim

ReckoNim is a [Nim](https://nim-lang.org) library for asking questions about data using [TypeSafe's Jev model](https://docs.typesafe.ai).

Write each question where your program uses the answer. ReckoNim collects questions about the same state and sends them to Jev in one request.

```nim
import reckonim

withState ticket:
  if ticket.message.feels "Is the customer describing something time-sensitive?":
    escalate(ticket)

  if ticket.customer.feels "Is this customer at risk of cancelling?":
    assignAccountManager(ticket)

  let team = ticket.message.choice("Which team should handle this?", %*{
    "billing":   "Payments, invoicing, refunds, payouts",
    "technical": "Bugs, outages, integrations",
    "sales":     "Pricing, upgrades, renewals"})
```

This block sends three questions in one request. Jev returns all three answers before the block's code runs.

ReckoNim uses two macros, three procedures, and the Nim standard library.

It handles request composition, request concurrency, and protects against a number of Jev quirks with the help of Nim's type system.

## Terms

| Term | Meaning |
|---|---|
| Question | A question about the data, such as `ticket.message.feels "..."`. |
| Answer | Jev's result for one question. |
| Judgment | The Nim value returned by a question: `Judgment[bool]`, `Judgment[string]`, or `Judgment[float]`. It contains the answer and question record. |
| State | The data Jev examines. Each request has one state. |
| Record | One independent value processed in the same way as other values. Each record gets its own state and request. |
| Focus path | The part of the state a question refers to. |
| Batch | The questions sent in one request. |
| Primitive | A Jev question type: `noul`, `choice`, or `score`. |
| Noul | Jev's yes/no question type. It returns a probability from 0 to 1. |

## Why batch questions?

You can send one question per request, but that sends the same state repeatedly. You can also build a batch yourself, but then you must maintain both the batch and the code that reads its answers.

ReckoNim builds the batch from the questions in your code. Adding or removing a question does not require a separate change to a request definition.

### Request time and token use

These results use `jev-1.13.0` and a state of 297 tokens.

| Questions | One batched request | One request per question | Reduction |
|---|---|---|---|
| 1 | 0.137 s, 327 tokens | 0.137 s, 327 tokens | None |
| 5 | 0.166 s, 443 tokens | 0.69 s, 1,635 tokens | 4.1× time, 3.7× tokens |
| 20 | 0.125 s, 888 tokens | 2.74 s, 6,540 tokens | 22× time, 7.4× tokens |
| 60 | 0.163 s, 2,088 tokens | 8.22 s, 19,620 tokens | 50× time, 9.4× tokens |

The batched results were measured. The one-request-per-question results were calculated from the single-question result.

A separate test in `examples/corpus` used 20 complaints of about 250 input tokens each. Each complaint received the same five questions, with the same wording, in both runs:

| Method | Requests | Input tokens |
|---|---:|---:|
| One request per question | 100 | 60,810 |
| One request per record | 20 | 20,722 |

Batching used 5× fewer requests and 2.9× fewer input tokens in that test. Those questions included `criteria` maps and were longer than the questions used for the first table.

In the first test, measured request times ranged from 0.125 to 0.166 seconds for 1–60 questions. That test did not show a meaningful increase in latency as questions were added. Each request used about 300 tokens for state and overhead, plus about 30 tokens per question.

TypeSafe also recommends sending several questions in one request, including questions whose answers may not be used. ReckoNim follows that approach: it sends every question in the block before running the code.

## How it works

Jev returns typed answers. ReckoNim also checks the Nim expressions used to identify the data being examined. A misspelled field can fail compilation instead of silently producing an answer about different data.

You write questions where their answers are used. ReckoNim creates the request and maps each answer back to its question.

### What `withState` does

At compile time, the macro:

1. Takes a snapshot of the state at the start of the block. Later changes in the block do not change what Jev examines.
2. Finds `feels`, `choice`, and `score` calls. It removes the state name from each receiver to create a focus path. For example, `ticket.customer.account.plan` becomes `customer.account.plan`.
3. Moves the questions to the start of the block and sends them in one request.
4. Replaces each question call with a read of its answer.

The request completes before the rest of the block runs.

### What it does not do

- It does not follow control flow to decide which questions to send. A question in a branch is sent even when that branch does not run.
- It does not combine questions about different states. Each Jev request has one state.
- It does not change ordinary Nim code in the block.
- It does not add a separate runtime. It generates code that uses the client and `Session` API. You can write the same request code yourself.

### What this changes

**Questions stay with the code that uses them.** There is no separate batch definition or answer-key lookup to maintain. Deleting a question also removes it from the request.

**Focus paths are checked.** Nim checks field access at compile time. ReckoNim also checks each focus path against the state snapshot before sending the request. See [Missing focus paths](#missing-focus-paths).

**Errors stay separate from answers.** A failed request does not become a `false` judgment. The error is raised when the program reads the affected judgment.

**Requests for independent records run concurrently.** `withEachState` defaults to 16 requests in flight. See [Many records](#many-records).

To inspect the requests, set `RECKONIM_TRACE=1`. It reports request counts, question counts, concurrency, and token counts.

### Code written by an LLM

When an LLM generates Jev integration code, several mistakes are possible:

| Mistake | Direct API or SDK code | With ReckoNim |
|---|---|---|
| Uses a chat-completions request format instead of Jev's format | The service rejects the request, or the code parses an answer incorrectly | The unsupported call does not compile |
| Sends one request per question | Repeats the state and increases request time and token use | Questions in a `withState` block are batched |
| Misspells a focus path or uses a field that was renamed | Jev may answer about the wrong part of the state without reporting an error | Invalid Nim field access fails compilation; missing data is checked before sending |
| Uses different keys to define a question and read its answer | An unused question or a failed lookup | No answer keys to maintain |
| Packs independent records into one state array | Answers can change depending on adjacent records | `withEachState` uses one state per record |
| Retries every error | Repeats invalid 4xx requests | Retries transport errors, 429, and 5xx once; does not retry other 4xx responses |
| Catches every error and returns `false` | Turns a request failure into a negative judgment | Request failures remain errors |

`usage-rules.md` lists the supported forms and compile errors for coding agents. It does not remove the need to choose useful questions, criteria, and decision thresholds. For example, a program can still use a `choice` result without checking its confidence.

### Which questions are sent?

Most question calls produce one question in the request. There are four exceptions:

- **Duplicate questions:** Identical questions are sent once. Each use reads the same answer. See [Identical questions are sent once](#identical-questions-are-sent-once).
- **Missing focus paths:** A question whose focus path does not resolve is omitted. If none of the paths resolve, no request is sent. Reading an omitted answer raises an error.
- **Unused branches:** Questions inside branches are sent even if those branches do not run. They still use tokens.
- **Loops:** A question inside a loop is sent once per iteration, in a separate request for each iteration.

`Session.pending` reports the number of questions to send. `Session.dropped` reports how many were omitted.

## Install and run

### Docker

Build the image and run the triage example:

```sh
docker build -t reckonim .
docker run --rm -e JEV_API_KEY=your-key reckonim
```

If `JEV_API_KEY` is already exported, you can pass it through with `-e JEV_API_KEY`. Docker does not warn you if the variable is missing. You can also load it from a file:

```sh
export JEV_API_KEY=...
docker run --rm --env-file .env reckonim
```

Run the test suite without a key or network access:

```sh
docker run --rm reckonim nimble test
```

To compile your own program in the container:

```sh
docker run --rm -e JEV_API_KEY -u "$(id -u):$(id -g)" \
  -v "$PWD":/work -w /work reckonim \
  nim c -d:ssl --nimcache:/tmp/nimcache --path:/reckonim/src -r yourprogram.nim
```

`-u` makes Nim's output files owned by your user. `--nimcache` keeps generated C files out of your project directory.

The `Dockerfile` uses `nimlang/nim:2.2.0` and adds `libssl-dev` for the `-d:ssl` build.

### Requirements

- A C compiler.
- Nim 2.0 or later, including `nimble`.
- OpenSSL 3 and its development files. `-d:ssl` links against `libssl` and `libcrypto`.
- A Jev API key in `JEV_API_KEY` for live requests.

ReckoNim uses no third-party Nim packages.

### Install Nim

The Nim installer works on Linux and macOS:

```sh
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

If you install Nim through a system package manager, check that it is version 2.0 or later:

```sh
nim --version
```

### Install a C compiler and OpenSSL

| System | Command |
|---|---|
| Debian, Ubuntu | `sudo apt install build-essential libssl-dev` |
| Fedora, RHEL | `sudo dnf install gcc openssl-devel` |
| Arch | `sudo pacman -S base-devel openssl` |
| Alpine | `sudo apk add build-base openssl-dev` |
| macOS | `xcode-select --install` and `brew install openssl@3` |

On macOS, pass the Homebrew OpenSSL paths to Nim:

```sh
export SSL=$(brew --prefix openssl@3)
nim c -d:ssl --passC:-I$SSL/include --passL:-L$SSL/lib --path:src -r examples/triage.nim
```

### Nix

The repository includes a flake. `nix develop` provides Nim 2.2 and OpenSSL without changing the system installation. The test suite has been verified with this configuration.

### Run the example

From the repository directory:

```sh
export JEV_API_KEY=...
nim c -d:ssl --path:src -r examples/triage.nim
```

Example output:

```text
ticket T-104 from Ada Okonkwo
  "This is the fourth time I have written about this. Our payo..."

actions
  - escalate to on-call
  - assign named account manager
  - queue for a human
  - route to billing
  - flag for tone-aware handling
```

The example asks six questions using all three primitives in one request. Five of them are written inside the expression that acts on the answer — an `if` condition, an operand of `and`, the condition of an `if` expression, a `.level` read — and none is bound to a name first. Enable the trace to see the request summary:

```text
withState ticket -> 1 request (live), 6 questions: 1 score, 4 noul, 1 choice [719 in / 215 out]
```

### Use ReckoNim in another program

From the repository directory:

```sh
nimble install
```

Then use `import reckonim` and compile with `-d:ssl`. You no longer need `--path:src`.

## Examples

| File | What it shows |
|---|---|
| `triage.nim` | Six judgments, three primitives, one request, each written in the expression that uses it. |
| `loop.nim` | A question inside a loop sends a request on each iteration. |
| `moderation.nim` | One answer used at three thresholds for actions with different error costs. |
| `review.nim` | A tuple state that includes both a commit message and the diff it describes. |
| `incident.nim` | Why `.level` and `round(.value)` can differ for a score. |
| `dedup.nim` | Five sites, three questions: what collapses, what does not, and why that is what makes writing the same question twice safe. Asserts its counts with no API key; `RECKONIM_LIVE=1` adds the live half. |
| `rfp.nim` | Five exact checks in Nim and four Jev judgments in one request. |
| `hazard.nim` | What happens when a focus path does not resolve. Requires the live service. |
| `corpus/` | 200 labeled complaints, five judgments each, compared with known labels. See [its README](examples/corpus/README.md). |

Run an example with tracing:

```sh
export JEV_API_KEY=...
RECKONIM_TRACE=1 nim c -d:ssl --path:src -r examples/loop.nim
```

`incident.nim` uses a committed recording by default. It needs no API key. Set `RECKONIM_LIVE=1` to query Jev instead; the result may differ from the recording.

`nimble test` compiles every example and runs `incident.nim`.

## One state per request

A `withState S` block collects questions whose receiver starts with `S`. Jev receives `S` as the state and the part after `S` as each question's focus path.

```nim
withState ticket:
  ticket.message.feels "..."                 # focus path: message
  ticket.customer.account.plan.feels "..."   # focus path: customer.account.plan

let reply = generateReply(ticket)

withState reply:                    # a different state and a second request
  reply.feels "..."                 # the receiver is the state itself
```

Jev accepts one state per request. To ask questions about two values together, put them in one state:

```nim
let review = (ticket: ticket, reply: reply)
withState review:
  review.ticket.message.feels "..."
  review.reply.feels "..."
```

A `withState` block nested inside another block creates a separate state and request. It does not extend the outer state.

## Many records

Use `withEachState` to process independent records with the same questions:

```nim
withEachState ticket in tickets:
  let team = ticket.message.choice("Which team should handle this?", %*{
    "billing":   "Payments, invoicing, refunds, payouts",
    "technical": "Bugs, outages, integrations",
    "sales":     "Pricing, upgrades, renewals"})

  if ticket.message.feels "Is the customer describing something time-sensitive?":
    escalate(ticket)
```

Each ticket gets its own state and request. All questions about that ticket are batched. `withEachState` sends requests concurrently, with 16 in flight by default.

In the `examples/corpus` test, processing 200 complaints took 9.5 seconds with four requests in flight and 3.7 seconds with sixteen. Neither setting produced a rejected request.

The block body still runs one record at a time, in input order, on your thread. You can append to a sequence inside it without a lock.

Use `withEachState` only when records are independent. A regular loop may depend on the previous iteration, exit early, or consume an iterator that must not be read ahead. ReckoNim does not assume that such a loop can run concurrently:

```nim
for ticket in tickets:       # iterations may depend on one another
  withState ticket:
    ...
```

### Why not put all records in one state?

Jev accepts arrays as state, so you could put several records in one request and use focus paths such as `[3].message`. ReckoNim does not do this.

Jev treats `inspect` as a hint about where to look, not as a selector that hides the rest of the state. Tests show that answers can change when other records appear in the same state:

| Test | Result |
|---|---|
| [pg-jev](https://github.com/realZachi/pg-jev) | 100% correct with 1–20 records per request; 92–98% with 40; 77–94% with 80. |
| [duckdb-jev #4](https://github.com/colliber/duckdb-jev/issues/4) | The same six tickets scored 1.19 alone, 1.53 among mild complaints, and 1.23 among severe complaints on a 0–3 scale. |

A changed score can cross a decision threshold even when the answer does not look obviously wrong.

Combining records also saves less input than combining questions about one record. The estimated reduction in fixed request overhead is about 2.5× for a short record and 12% for a 2,000-token record. The record's text still has to be sent once either way.

### When one record fails

A failed record does not stop other records. ReckoNim stores that record's original error and status and raises them when your code reads one of its judgments. It does not return `false`.

A transport failure, HTTP 429, or HTTP 5xx response gets one additional attempt after the other requests finish. Other HTTP 4xx responses are not retried.

`RECKONIM_TRACE=1` reports the number of requests, retries, and failures for the set.

## Question types

| Primitive | Nim call | Result | Accessors |
|---|---|---|---|
| `noul` | `feels(q, criteria = ..., atLeast = 0.5)` | `Judgment[bool]` | `.probability`, `.atLeast(x)` |
| `choice` | `choice(q, %*{...})` | `Judgment[string]` | `.value`, `.confidence`, `.probabilities` |
| `score` | `score(q, %*[...])` | `Judgment[float]` | `.value`, `.level`, `.confidence`, `.legend` |

All three question types accept `criteria` to specify how results should be assigned. The short form `feels "urgent"` is useful in examples, but real applications should provide enough criteria for the decision being made.

Each call returns a `Judgment[T]` with the answer and question record. For a `feels` judgment, Nim's `toBool` converter allows direct use in a condition:

```nim
if ticket.message.feels "Is this urgent?":
  escalate(ticket)
```

You can also read its `.probability` and apply a different threshold with `.atLeast(x)`.

## Focus paths

### Use qualified receivers

Write `ticket.message.feels(...)`, not `message.feels(...)`.

The receiver must start with the state name used by `withState`. This lets the macro remove that prefix to produce a focus path. Nim can then check the field expression at compile time, and ReckoNim can check the resulting path against the state data before sending the request.

### Missing focus paths

Jev's `inspect` field is a hint, not a strict selector. When a path does not exist, Jev may still answer based on another part of the state.

For example:

```text
state:    {"account": null, "note": "THE PLAN IS ENTERPRISE, EXTREMELY HIGH VALUE"}
question: inspect `account.plan` - "Is this a high-value plan?"
from Jev: 0.89
```

`account.plan` does not exist, but Jev returned a probability based on other data. That answer cannot be treated as an answer about `account.plan`.

ReckoNim checks focus paths twice:

1. **At compile time:** Nim checks the receiver expression. A field missing from the Nim type stops compilation.
2. **Before the request:** ReckoNim resolves each focus path against a snapshot of the actual state. This check does not call Jev.

The second check catches cases the type checker cannot detect, such as a missing JSON key, `null` or `nil`, an empty collection, an out-of-range index, a parent of the wrong JSON type, or indexing an object as an array.

If a path does not resolve, ReckoNim omits its question from the request and records the error. It does not raise the error immediately because the question may be inside a branch that never runs.

If the program reads the omitted answer, ReckoNim raises an error with the reason and source line:

```text
refused: `account` is null, so it has no field `plan` - hazard.nim:49
```

A condition such as `if j:` counts as reading the judgment. An unused question with a missing path does not stop the program; a used one does. See `examples/hazard.nim`.

### Questions are resolved before the block runs

A question appears where the program uses its answer, but its answer comes from the request made at the start of the block.

Outside the macro, the lower-level `Session` API lets you create questions and run the request yourself. Reading a judgment before `run()` raises `UnresolvedError`; it does not return `false`.

```nim
var s = newSession(activeClient(), "ticket", %ticket)
let urgent = s.feels("message", "Is this urgent?")

if urgent: ...        # UnresolvedError
s.run()               # sends the request
if urgent: ...        # reads the answer
```

Inside `withState`, the macro runs the request before executing the rest of the block. You do not call `run()` yourself.

### Identical questions are sent once

ReckoNim identifies a question using a slug and a hash of its normalized record:

```text
urgent@ticket.message#a3f19c2b
```

Source location is not part of that identity. Moving a question to another line does not change its identity or invalidate an otherwise matching recording.

```nim
if ticket.message.feels "urgent": a()
if ticket.message.feels "urgent": b()   # one question, two reads
```

These identical questions share one answer. Not two samples of it: three separate requests can return three numbers that straddle a threshold, while one answer read three times cannot.

This is what makes "write the question where its answer is used" safe. Independent rules that happen to need the same judgment each write it, at whatever bar their own action deserves, without coordinating on a shared binding:

```nim
withState payout:
  if payout.feels(Exit, criteria = C, atLeast = 0.9): freeze()
  if payout.feels(Exit, criteria = C, atLeast = 0.6): manualReview()
  if payout.feels(Exit, criteria = C, atLeast = 0.3): auditNote()
```

Three sites, one question, one answer. `atLeast` is a coercion policy on the judgment, not part of the question, so it does not split them.

What is part of the identity: state root, focus path, primitive, instructions, and criteria. Change any of those — including rewording the question by one word — and you have a second question, billed and answered separately. Keep repeated question text in a `const` so copies cannot drift apart.

`examples/dedup.nim` shows five sites collapsing to three questions and asserts the counts. That half needs no API key, because dedup is decided while the batch is built.

### Do not mix up probability, confidence, and score

- **Noul probability:** `.probability` is the probability of “yes.” A value of 0.5 means “yes” and “no” are equally probable. A `noul` judgment has no `.confidence` field; accessing it raises an error.
- **Score:** `.value` is the probability-weighted mean of level indexes. `.level` is the most probable level. For `{0: 0.45, 1: 0.1, 2: 0.45}`, `.value` is 1.0, but level 1 has only 10% of the probability. Do not derive `.level` by rounding `.value`.
- **Choice:** `.value` is the selected option. A selection can have low confidence. Check `.confidence` against a threshold appropriate to the action before using the choice.

### Text inside a question is not a checked focus path

ReckoNim cannot check field names embedded in ordinary question text. For example:

| State | Question | Jev answer |
|---|---|---:|
| `{"food": "a BLT on rye"}` | `Is \`food\` a sandwich?` | 0.99 |
| `{"lunch": "a BLT on rye"}` | `Is \`food\` a sandwich?` | 0.98 |

The second state has no `food` field, but Jev still answers using `lunch`.

The `feels`, `choice`, and `score` calls produce structured `inspect` paths that ReckoNim checks. If you create a `QuestionSite` manually with a plain-text field reference, you are responsible for checking that reference.

## Record, replay, and trace

`nim c -r` leaves the compiled binary beside its source. After building `examples/triage.nim`, you can use:

```sh
RECKONIM_RECORD=run.json   ./examples/triage   # save requests and responses
RECKONIM_REPLAY=run.json   ./examples/triage   # use the recording; do not call Jev
RECKONIM_TRACE=1           ./examples/triage   # print request details to stderr
```

Replay does not require an API key. Question identities do not include source locations, and the FNV-1a hash is fixed, so moving code or changing compiler versions does not by itself invalidate a recording.

If replay cannot find a matching recorded question, ReckoNim raises an error. It does not silently send a live request.

Use recordings for tests that need stable answers. In live tests, an unclear question can produce answers that vary by about 0.02 between runs. That difference matters near a decision threshold.

## Limits and errors

The Jev limits used for this version are:

| Limit | Value |
|---|---:|
| Tokens per request | 64,000 |
| State plus longest question | 32,000 tokens |
| Published request rate | 1,200 requests/minute |
| Published input-token price | $42 per billion tokens |
| Output-token price | Free |

These limits and prices may change. ReckoNim uses the configured service limits; the table describes the values used during testing.

### Concurrent requests

The published request rate is 20 per second. In a test using 200 requests from `examples/corpus`, the service accepted higher short-term rates:

| Requests in flight | Time for 200 requests | Requests/second | Rejected |
|---:|---:|---:|---|
| 4 | 9.5 s | 21 | None |
| 8 | 5.5 s | 36 | None |
| 16 | 3.7 s | 54 | None |
| 32 | 2.6 s | 77 | None |
| 64 | 1.5 s | 133 | None |

`withEachState` defaults to 16 requests in flight. The test at 64 reached about 134,000 tokens per second, against a published limit of 250,000. The service describes its limits as dynamic. A setting that works in one test may trigger rate limits on another account or workload.

### Change the concurrency setting

Set the limit without recompiling:

```sh
RECKONIM_IN_FLIGHT=32 ./yourprogram
```

Or set it in Nim:

```nim
activeClient().inFlight = 32
```

ReckoNim rejects values below 1 and values that are not numbers.

Trace output includes the concurrency setting, retry count, and failure count:

```text
runAll -> 200 state(s), 200 request(s) at 32 in flight, 0 rescheduled, 0 parked
```

When comparing settings, check retries and failures as well as elapsed time. A higher concurrency setting may take longer if it causes rate-limit retries.

### Error handling

ReckoNim keeps these conditions separate from a negative judgment: invalid program state, missing API key, transport failure, service failure, bad response, timeout, rate limit, state serialization failure, and replay with no matching recording.

A missing API key is reported before a live request is made.

With `withEachState`, an error is stored for the affected record. Other records continue, and the error is raised when the program reads that record's judgment. See [When one record fails](#when-one-record-fails).

## Tests

```sh
nimble test
```

Five test suites use a stub transport. Three additional source files must fail to compile: one uses a state root outside the block, one has a focus path that does not resolve, and one uses a state root that is not a plain identifier.

`tests/test_jev.nim` includes a live test. Set `RECKONIM_LIVE=1` and provide an API key to run it against Jev.

A stub transport cannot verify that requests are in flight at the same time. `tests/test_eachstate.nim` also starts a local server that delays each answer by 200 ms. Its test requires four requests to complete in less than half the time they would take sequentially.

## Status

Version 0.1.0. Statements about Jev API behavior in this README are based on tests against the live service.

The following features are not included in this release:

| Feature | Condition for adding it |
|---|---|
| Batch questions inside a loop over one state | A real use case needs it. Each iteration currently makes its own request. Use `withEachState` for independent records. |
| Unqualified receivers | Qualified receivers become difficult to use in real code. |
| Enum results from `choice` | String results cause a production error. |
| Cache shared across runs | Record and replay are not sufficient. |
| Browser playground | Someone other than the author needs to run code there. |
| Additional evaluator | A second evaluator is available. |

## Rules for coding agents

`usage-rules.md` lists the supported API forms, compile errors, judgment accessors, batching rules, and stub-transport testing pattern.

For code written by an agent, copy that file into the project or append it to `AGENTS.md`.

## License

MIT.
