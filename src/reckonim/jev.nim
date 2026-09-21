## ReckoNim - Jev client. See PLAN.md sections 5, 6, 8, 9.
##
## Everything here is independent of the `withState` macro: construct QuestionSites,
## batch the ones sharing a state, send one request, read answers back. The macro
## (phase 3) becomes a source of QuestionSites and nothing more.

import std/[json, tables, algorithm, sequtils, strutils, os, httpclient, asyncdispatch]

const
  DefaultEndpoint* = "https://api.typesafe.ai/v1/systemone"
  DefaultModel* = "jev-latest"

  # models.md, jev-1.13.0
  MaxRequestTokens* = 64_000
  MaxStatePlusQuestionTokens* = 32_000

  RequestTimeoutMs = 30_000

  DefaultInFlight* = 16
    ## How many of `submitAll`'s requests are on the wire at once, unless
    ## `Client.inFlight` or `RECKONIM_IN_FLIGHT` says otherwise. Nothing a
    ## `withEachState` block contains has to know this number.
    ##
    ## Measured live over examples/corpus - 200 requests at five widths, every
    ## run reporting 0 rescheduled and 0 parked:
    ##
    ##   width   wall    req/s   gain over the width below
    ##       4   9.5s       21   -
    ##       8   5.5s       36   1.73x
    ##      16   3.7s       54   1.49x
    ##      32   2.6s       77   1.42x
    ##      64   1.5s      133   1.73x
    ##
    ## models.md documents 1200 requests/minute, which is 20/s. It does not bind:
    ## 64 sustained 6.7x that without a single 429. Do not re-derive this constant
    ## from that number.
    ##
    ## 16 rather than 64, on three grounds. The token limit is the one that looks
    ## real - 64 ran at 134k tokens/s against a documented 250k, while 16 sits at
    ## 22% of it. models.md says the limits are "adjusting dynamically" and "can
    ## change without notice", so a default at 6.7x the published rate borrows
    ## against a number the vendor is moving. And the gain is shallow: 16 already
    ## takes 2.6x of the 6.3x that 64 offers.
    ##
    ## Raise it if your account's limits are higher than the published ones, or
    ## if a measurement on your own workload says so. This one is the default,
    ## not a ceiling.
    ##
    ## ponytail: waves, so each idles until its slowest member returns, and a
    ## width far above the collection size buys nothing. A sliding window or a
    ## token bucket only if a measured workload shows either costs something.

type
  Primitive* = enum
    pNoul = "noul"
    pChoice = "choice"
    pScore = "score"

  QuestionSite* = object ## Normalized judgment. A flat record, not a graph node.
    slug*: string           ## readable label, e.g. "urgent"
    stateRoot*: string      ## identifier of the withState subject, e.g. "ticket"
    focusPath*: string      ## state-relative; "" when the receiver is the root
    primitive*: Primitive
    instructions*: JsonNode ## string or structured object
    criteria*: JsonNode     ## nil when absent; a list for pScore, a map otherwise
    sourceLocation*: string ## diagnostics only - deliberately excluded from the id

  Batch* = object ## The questions from one `withState`, destined for one request.
    stateRoot*: string
    state*: JsonNode
    model*: string
    sites*: OrderedTable[string, QuestionSite] ## keyed by id
    unresolvable*: Table[string, string] ## id -> why its focus path missed

  Answers* = object
    model*: string
    inputTokens*, outputTokens*: int
    byId*: Table[string, JsonNode]
    unresolvable*: Table[string, string]
    failure*: ref JevError ## the request failed; re-raised by every read below

  Transport* = proc (payload: JsonNode): JsonNode ## nil means real HTTP

  Client* = ref object
    endpoint*, apiKey*, model*: string
    transport*: Transport
    recordTo*, replayFrom*: string
    trace*: bool
    maxRetries*: int
    inFlight*: int
      ## Requests on the wire at once in `submitAll`. Defaults to
      ## `DefaultInFlight`, or to `RECKONIM_IN_FLIGHT` when that is set. Assign
      ## to it for a workload whose measured best width is not the default.
    requests*, questionsAsked*, inputTokens*, outputTokens*: int
      ## Running totals since the client was built, for cost reporting. A replayed
      ## request still counts - it is what the run would have cost live.
    replayStore: Table[string, JsonNode]
    recordStore: JsonNode

  JevError* = object of CatchableError          ## base: never coerces to a value
  JevTransportError* = object of JevError       ## could not reach the service
  JevServiceError* = object of JevError         ## reached it, non-2xx
    status*: int ## the HTTP status, so a caller can tell 429 from 400
  JevProtocolError* = object of JevError        ## 2xx but the body made no sense
  JevLimitError* = object of JevError           ## our own pre-send check
  JevConfigError* = object of JevError          ## nothing to send with: no API key
  JevIdCollisionError* = object of JevError     ## two different sites, one id
  ReplayMissError* = object of JevError         ## replay file has no matching request
  UnresolvablePathError* = object of JevError   ## focus path missed in the snapshot

# ---------------------------------------------------------------- canonical JSON

proc canonical*(n: JsonNode): string =
  ## JSON with object keys sorted, so hashing is insensitive to field order.
  ## std/json objects preserve insertion order, which would otherwise make the
  ## same logical request hash two different ways.
  if n.isNil: return "null"
  case n.kind
  of JObject:
    var keys = toSeq(n.fields.keys)
    sort(keys)
    "{" & keys.mapIt(escapeJson(it) & ":" & canonical(n[it])).join(",") & "}"
  of JArray:
    "[" & n.elems.mapIt(canonical(it)).join(",") & "]"
  else:
    $n

proc hash8(s: string): string =
  ## FNV-1a, 32 bits. Pinned here rather than taken from std/hashes, which makes
  ## no cross-version stability promise - a recording has to outlive a compiler
  ## upgrade, not just a source edit.
  ##
  ## ponytail: 32 bits is not collision-proof and is not a cryptographic digest.
  ## A collision between two *different* sites would silently share one answer,
  ## so `add` below detects that case and raises rather than relying on width.
  var h = 0x811c9dc5'u32
  for ch in s:
    h = h xor uint32(ord(ch))
    h = h * 0x01000193'u32
  toLowerAscii(toHex(h, 8))

# ---------------------------------------------------------------- QuestionSite

proc slugify*(s: string, limit = 24): string =
  ## Readable id fragment: lowercase alphanumerics joined by single underscores,
  ## clipped at a word boundary. These end up on the wire and in trace output, so
  ## a mid-word cut ("is_this_a_high_risk_acco") is worth the few extra lines.
  var words: seq[string]
  var cur = ""
  for ch in s:
    if ch.isAlphaNumeric:
      cur.add ch.toLowerAscii
    elif cur.len > 0:
      words.add cur
      cur = ""
  if cur.len > 0: words.add cur

  for w in words:
    if result.len == 0: result = w              # always take one, however long
    elif result.len + 1 + w.len <= limit: result.add '_' & w
    else: break
  if result.len > limit: result.setLen limit    # a single oversized word

proc normalized*(site: QuestionSite): JsonNode =
  ## The part of a site that determines its identity. `sourceLocation` is absent
  ## by design: unrelated edits move line numbers, and a recording must survive
  ## that. See PLAN.md section 6.
  result = %*{
    "stateRoot": site.stateRoot,
    "focusPath": site.focusPath,
    "primitive": $site.primitive,
    "instructions": site.instructions,
  }
  if not site.criteria.isNil:
    result["criteria"] = site.criteria

proc id*(site: QuestionSite): string =
  ## `urgent@ticket.message#a3f19c2b`. Doubles as the Jev question key - verified
  ## that `@ . [ ] # :` pass through the API unmodified.
  let path = if site.focusPath.len > 0: site.stateRoot & "." & site.focusPath
             else: site.stateRoot
  site.slug & "@" & path & "#" & hash8(canonical(site.normalized))

proc describe(n: JsonNode): string =
  case n.kind
  of JNull: "null"
  of JBool: "a boolean"
  of JInt, JFloat: "a number"
  of JString: "a string"
  of JArray: "an array"
  of JObject: "an object"

proc resolveExact(state: JsonNode, path: string): string =
  ## Returns "" when `path` resolves in the snapshot, otherwise why it does not.
  ##
  ## This check exists because Jev does not report a bad `inspect` path. It is a
  ## hint, not a selector: when it misses, the model falls back to judging the
  ## whole state and answers *confidently about the wrong subject*. Measured - a
  ## path that misses, next to an unrelated field reading "ENTERPRISE, EXTREMELY
  ## HIGH VALUE", returned 0.92. Nothing in the response distinguishes that from
  ## a correct answer, so it has to be caught before sending.
  var node = state
  var seen = ""
  var i = 0

  template where: string = (if seen.len > 0: "`" & seen & "`" else: "the state")

  while i < path.len:
    if path[i] == '.':
      inc i
    elif path[i] == '[':
      let close = path.find(']', i)
      if close < 0: return "malformed focus path `" & path & "`"
      let key = path[i + 1 ..< close]
      i = close + 1
      case node.kind
      of JArray:
        var idx: int
        try: idx = parseInt(key)
        except ValueError:
          return where & " is an array, but `" & key & "` is not an integer index"
        if idx < 0 or idx >= node.len:
          return where & " has " & $node.len & " element(s), so [" & key & "] is out of range"
        node = node[idx]
        seen.add "[" & key & "]"
      of JObject:
        return where & " is an object - write `" & seen & "." & key &
               "` rather than bracket indexing"
      else:
        return where & " is " & node.describe & ", which cannot be indexed"
    else:
      var j = i
      while j < path.len and path[j] notin {'.', '['}: inc j
      let name = path[i ..< j]
      i = j
      if node.kind != JObject:
        return where & " is " & node.describe & ", so it has no field `" & name & "`"
      if name notin node:
        var have: seq[string]
        for k in node.keys:
          if have.len >= 6: have.add "..."; break
          have.add k
        return where & " has no field `" & name & "`" &
               (if have.len > 0: " (it has: " & have.join(", ") & ")" else: " (it is empty)")
      node = node[name]
      if seen.len > 0: seen.add "."
      seen.add name

  if node.kind == JNull:
    return where & " is null"
  ""

proc resolveFocus*(state: JsonNode, path: string, stateRoot = ""): string =
  ## As `resolveExact`, but also accepts a root-prefixed path. The docs write
  ## `compare` entries as `ticket.sender.email` while `inspect` is written
  ## state-relative; measured, the service accepts both, so neither form should
  ## be rejected here.
  result = resolveExact(state, path)
  if result.len > 0 and stateRoot.len > 0 and path.startsWith(stateRoot & "."):
    if resolveExact(state, path[stateRoot.len + 1 .. ^1]).len == 0:
      return ""

proc focusPathsIn*(instructions: JsonNode): seq[string] =
  ## Every path the service will actually try to follow. `QuestionSite.focusPath`
  ## is ReckoNim's own bookkeeping; `inspect` and `compare` are what ship. Those
  ## are the ones that must be checked - validating only the bookkeeping field
  ## leaves hand-built structured instructions unguarded.
  if instructions.isNil or instructions.kind != JObject: return
  let inspect = instructions{"inspect"}
  if not inspect.isNil and inspect.kind == JString:
    result.add inspect.getStr
  let compare = instructions{"compare"}
  if not compare.isNil and compare.kind == JArray:
    for p in compare:
      if p.kind == JString: result.add p.getStr

proc toJson*(site: QuestionSite): JsonNode =
  result = %*{"type": $site.primitive, "instructions": site.instructions}
  if not site.criteria.isNil:
    result["criteria"] = site.criteria

proc focusedInstructions*(focusPath, question: string): JsonNode =
  ## The common shape: `{"inspect": "<path>", "question": "<q>"}`. An empty focus
  ## path emits no `inspect` key, which is correct when the receiver *is* the
  ## state (`withState reply:` over a bare string).
  if focusPath.len > 0: %*{"inspect": focusPath, "question": question}
  else: %*{"question": question}

# ---------------------------------------------------------------- Batch

proc initBatch*(stateRoot: string, state: JsonNode, model = DefaultModel): Batch =
  Batch(stateRoot: stateRoot, state: state, model: model,
        sites: initOrderedTable[string, QuestionSite]())

proc add*(b: var Batch, site: QuestionSite): string {.discardable.} =
  ## Returns the site's id. Two textually identical judgments collapse onto one
  ## question - that is the intended dedup (measured: the same question under two
  ## keys returns identical values). Two *different* sites sharing an id is a hash
  ## collision and raises.
  ##
  ## A judgment whose focus path misses in the snapshot produces no question.
  ## Raising here would make speculative evaluation observable - a judgment in a
  ## branch the program never reaches would kill an otherwise-fine run. Instead
  ## it is recorded and reading it raises, so an unreached site stays harmless
  ## and a reached one fails loudly rather than answering about the wrong subject.
  result = site.id
  var paths = @[site.focusPath]
  for p in focusPathsIn(site.instructions):
    if p notin paths: paths.add p
  for p in paths:
    let why = resolveFocus(b.state, p, b.stateRoot)
    if why.len > 0:
      b.unresolvable[result] = why &
        (if site.sourceLocation.len > 0: " - " & site.sourceLocation else: "")
      return

  if result in b.sites:
    let existing = b.sites[result]
    if canonical(existing.normalized) != canonical(site.normalized):
      raise newException(JevIdCollisionError,
        "id collision on '" & result & "' between " & existing.sourceLocation &
        " and " & site.sourceLocation & " - widen hash8")
  else:
    b.sites[result] = site

proc toRequest*(b: Batch): JsonNode =
  var questions = newJObject()
  for qid, site in b.sites:
    questions[qid] = site.toJson
  %*{"state": b.state, "model": b.model, "questions": questions}

# ---------------------------------------------------------------- limits

proc estimateTokens(s: string): int =
  # ponytail: chars/4. Deliberately *under*estimates JSON (punctuation-dense text
  # runs nearer 3 chars/token), so this errs toward letting a borderline request
  # through to the server, whose own validation is precise and reports a field
  # path. Swap in a real tokenizer only if false negatives actually bite.
  s.len div 4

proc checkLimits*(b: Batch) =
  let stateTokens = estimateTokens(canonical(b.state))
  var total = stateTokens
  var worst = 0
  var worstId = ""
  for qid, site in b.sites:
    let qt = estimateTokens(canonical(site.toJson))
    total += qt
    if qt > worst: (worst, worstId) = (qt, qid)
  if stateTokens + worst > MaxStatePlusQuestionTokens:
    raise newException(JevLimitError,
      "state '" & b.stateRoot & "' (~" & $stateTokens & " tok) plus largest question '" &
      worstId & "' (~" & $worst & " tok) exceeds the " &
      $MaxStatePlusQuestionTokens & " token limit")
  if total > MaxRequestTokens:
    raise newException(JevLimitError,
      "request for state '" & b.stateRoot & "' is ~" & $total & " tokens over " &
      $b.sites.len & " questions, exceeding the " & $MaxRequestTokens & " token limit")

# ---------------------------------------------------------------- Answers

proc parseAnswers*(body: JsonNode): Answers =
  if body.isNil or body.kind != JObject or "answers" notin body:
    raise newException(JevProtocolError, "response has no 'answers' object: " & $body)
  result.model = body{"model"}.getStr
  result.inputTokens = body{"usage", "input_tokens"}.getInt
  result.outputTokens = body{"usage", "output_tokens"}.getInt
  for qid, ans in body["answers"]:
    result.byId[qid] = ans

proc retryable*(e: ref JevError): bool =
  ## Worth one more attempt later. A 4xx means the request itself is wrong, and
  ## sending it again would only be wrong again.
  if e.isNil: false
  elif e of JevTransportError: true
  elif e of JevServiceError:
    let s = (ref JevServiceError)(e).status
    s == 429 or s >= 500
  else: false

proc answer*(a: Answers, id: string): JsonNode =
  if not a.failure.isNil:
    # The request never produced an answer. Raise the original error, not a
    # wrapper, so the status and body survive and `except JevServiceError` still
    # catches what it would have caught had this been the only state in flight.
    raise a.failure
  if id in a.unresolvable:
    raise newException(UnresolvablePathError,
      "judgment '" & id & "' was never asked: " & a.unresolvable[id])
  if id notin a.byId:
    raise newException(JevProtocolError, "no answer for question '" & id & "'")
  a.byId[id]

proc noul*(a: Answers, id: string): float =
  ## P(yes), 0..1. Noul carries no confidence field - this value *is* the answer.
  a.answer(id){"noul"}.getFloat

proc choice*(a: Answers, id: string): string =
  a.answer(id){"choice"}.getStr

proc confidence*(a: Answers, id: string): float =
  ## Choice and score only. Asking a noul for confidence is a bug, not a default.
  let ans = a.answer(id)
  if "confidence" notin ans:
    raise newException(JevProtocolError,
      "question '" & id & "' is a " & ans{"type"}.getStr & " and carries no confidence")
  ans["confidence"].getFloat

proc field(a: Answers, id, key: string): JsonNode =
  ## `{}` yields nil for a missing key, and iterating or indexing a nil JsonNode
  ## segfaults. A malformed 2xx body is a protocol error, not a crash.
  let ans = a.answer(id)
  result = ans{key}
  if result.isNil or result.kind != JObject:
    raise newException(JevProtocolError,
      "question '" & id & "' is a " & ans{"type"}.getStr & " and carries no " & key)

proc probabilities*(a: Answers, id: string): OrderedTable[string, float] =
  for k, v in a.field(id, "probabilities"):
    result[k] = v.getFloat

proc legend*(a: Answers, id: string): JsonNode =
  a.field(id, "legend")

proc score*(a: Answers, id: string): float =
  ## The probability-weighted mean of level indices, NOT the most likely level.
  ## Measured: probabilities {0:0.73, 1:0.27, 2:0.0} returns score 0.27.
  a.answer(id){"score"}.getFloat

proc level*(a: Answers, id: string): int =
  ## The most likely level. Deliberately computed from the distribution rather
  ## than by rounding `score` - see the comment above; they are different numbers.
  var best = -1.0
  result = -1
  for k, v in a.probabilities(id):
    if v > best: (best, result) = (v, parseInt(k))
  if result < 0:
    raise newException(JevProtocolError, "question '" & id & "' has no probabilities")

# ---------------------------------------------------------------- record / replay

proc loadReplay(path: string): Table[string, JsonNode] =
  if not fileExists(path):
    raise newException(ReplayMissError, "replay file not found: " & path)
  for entry in parseJson(readFile(path)):
    result[entry["key"].getStr] = entry["response"]

proc flushRecord(c: Client) =
  writeFile(c.recordTo, pretty(c.recordStore))

# ---------------------------------------------------------------- Client

proc envInFlight(): int =
  ## `RECKONIM_IN_FLIGHT` exists so a width can be swept without a recompile -
  ## which is how the default was arrived at. A bad value is refused rather than
  ## rounded into something that silently is not what was asked for.
  let raw = getEnv("RECKONIM_IN_FLIGHT").strip
  if raw.len == 0: return DefaultInFlight
  try: result = parseInt(raw)
  except ValueError:
    raise newException(JevConfigError,
      "RECKONIM_IN_FLIGHT must be a whole number, got '" & raw & "'")
  if result < 1:
    raise newException(JevConfigError,
      "RECKONIM_IN_FLIGHT must be at least 1, got " & $result)

proc newClient*(apiKey = getEnv("JEV_API_KEY"), model = DefaultModel,
                endpoint = DefaultEndpoint, transport: Transport = nil): Client =
  result = Client(endpoint: endpoint, apiKey: apiKey, model: model,
                  transport: transport, maxRetries: 3, inFlight: envInFlight(),
                  recordTo: getEnv("RECKONIM_RECORD"),
                  replayFrom: getEnv("RECKONIM_REPLAY"),
                  trace: getEnv("RECKONIM_TRACE").len > 0,
                  recordStore: newJArray())
  if result.replayFrom.len > 0:
    result.replayStore = loadReplay(result.replayFrom)
  if result.recordTo.len > 0 and fileExists(result.recordTo):
    result.recordStore = parseJson(readFile(result.recordTo))

proc postAsync(c: Client, payload: JsonNode): Future[JsonNode] {.async.} =
  ## The only place a request leaves. Async so `submitAll` can have several in
  ## flight; `post` below drives it to completion for the single-request path, so
  ## nothing above this becomes `{.async.}`.
  var delayMs = 500
  for attempt in 0 .. c.maxRetries:
    var status = 0
    var body = ""
    var err = ""

    let http = newAsyncHttpClient()
    http.headers = newHttpHeaders({
      "Authorization": "Bearer " & c.apiKey,
      "Content-Type": "application/json"})
    try:
      # AsyncHttpClient takes no timeout, unlike its blocking sibling, so the
      # deadline has to be imposed here.
      # ponytail: on a timeout the underlying request is abandoned rather than
      # cancelled - std/asyncdispatch has no cancellation. It is bounded by the
      # retry count, so the leak cannot accumulate.
      let fut = http.request(c.endpoint, HttpPost, body = $payload)
      if await withTimeout(fut, RequestTimeoutMs):
        let resp = fut.read()
        status = resp.code.int
        body = await resp.body
      else:
        err = "no response within " & $RequestTimeoutMs & "ms"
    except CatchableError as e:
      err = e.msg
    http.close()

    if err.len > 0:
      if attempt == c.maxRetries:
        raise newException(JevTransportError, "cannot reach " & c.endpoint & ": " & err)
      await sleepAsync(delayMs); delayMs *= 2
      continue

    if status in 200 .. 299:
      try: return parseJson(body)
      except CatchableError:
        raise newException(JevProtocolError, "unparseable response body: " & body)

    # 429 and 5xx are worth another go; 4xx means the request itself is wrong.
    if (status == 429 or status >= 500) and attempt < c.maxRetries:
      await sleepAsync(delayMs); delayMs *= 2
      continue

    var e = newException(JevServiceError, "HTTP " & $status & ": " & body)
    e.status = status
    raise e

proc post(c: Client, payload: JsonNode): JsonNode =
  waitFor c.postAsync(payload)

proc traceBatch(c: Client, b: Batch, a: Answers, source: string) =
  var counts: CountTable[Primitive]
  for _, site in b.sites: counts.inc site.primitive
  var parts: seq[string]
  for p, n in counts: parts.add $n & " " & $p
  stderr.writeLine "withState " & b.stateRoot & " -> 1 request (" & source & "), " &
    $b.sites.len & " questions: " & parts.join(", ") &
    " [" & $a.inputTokens & " in / " & $a.outputTokens & " out]" &
    (if b.unresolvable.len > 0: "; " & $b.unresolvable.len & " dropped (unresolvable focus)"
     else: "")

proc noQuestions(c: Client, b: Batch): Answers =
  ## Every judgment's focus path missed. Nothing to ask, but this is not an error
  ## yet - only reading one of them is.
  if b.unresolvable.len == 0:
    raise newException(JevLimitError, "batch for state '" & b.stateRoot & "' has no questions")
  if c.trace:
    stderr.writeLine "withState " & b.stateRoot & " -> no request, all " &
      $b.unresolvable.len & " judgment(s) have unresolvable focus paths"
  Answers(model: b.model, unresolvable: b.unresolvable)

proc prepare(c: Client, b: var Batch): tuple[payload: JsonNode, key: string,
                                             local: JsonNode, source: string] =
  ## Everything up to the network. `local` comes back non-nil when replay or a
  ## stub transport already answered, so no request needs to leave at all.
  if b.model.len == 0: b.model = c.model
  b.checkLimits()
  let payload = b.toRequest
  let key = hash8(canonical(payload))

  if c.replayFrom.len > 0:
    if key notin c.replayStore:
      raise newException(ReplayMissError,
        "no recording for state '" & b.stateRoot & "' (key " & key & ") in " & c.replayFrom)
    return (payload, key, c.replayStore[key], "replay")
  if c.transport != nil:
    return (payload, key, c.transport(payload), "stub")
  if c.apiKey.len == 0:
    raise newException(JevConfigError,
      "no API key: set JEV_API_KEY, or pass one to newClient. " &
      "(RECKONIM_REPLAY=<file> needs no key.)")
  (payload, key, nil, "live")

proc finish(c: Client, b: Batch, payload, body: JsonNode, key, source: string): Answers =
  ## Everything after it. Recording is appended but not flushed - `submit` writes
  ## the file once, and `submitAll` writes it once for the whole wave rather than
  ## rewriting a growing file per state.
  result = parseAnswers(body)
  result.unresolvable = b.unresolvable

  inc c.requests
  c.questionsAsked += b.sites.len
  c.inputTokens += result.inputTokens
  c.outputTokens += result.outputTokens

  if c.recordTo.len > 0 and source != "replay":
    c.recordStore.add %*{"key": key, "request": payload, "response": body}
  if c.trace:
    c.traceBatch(b, result, source)

proc submit*(c: Client, b: var Batch): Answers =
  ## One batch, one request. Replay short-circuits the network entirely.
  if b.sites.len == 0: return c.noQuestions(b)
  let p = c.prepare(b)
  let body = if p.local.isNil: c.post(p.payload) else: p.local
  result = c.finish(b, p.payload, body, p.key, p.source)
  if c.recordTo.len > 0 and p.source != "replay": c.flushRecord()

proc postMany(c: Client, idx: seq[int], payloads: seq[JsonNode], width: int,
              bodies: var seq[JsonNode], errs: var seq[ref JevError]) =
  ## Run `idx`'s requests `width` at a time, writing each result back at its own
  ## index. Failures land in `errs` rather than aborting the rest.
  ##
  ## ponytail: waves, so the tail of each one idles while its slowest member
  ## finishes. A sliding window recovers that; build one only if a measured run
  ## shows the idle time matters.
  let width = max(1, width) ## a width of 0 would make no progress at all
  var i = 0
  while i < idx.len:
    let stop = min(i + width, idx.len)
    var futs: seq[Future[JsonNode]]
    for k in i ..< stop: futs.add c.postAsync(payloads[idx[k]])
    for k in i ..< stop:
      try: bodies[idx[k]] = waitFor futs[k - i]
      except JevError as e: errs[idx[k]] = e
    i = stop

proc submitAll*(c: Client, batches: var seq[Batch]): seq[Answers] =
  ## Many independent states, one request each, several requests in flight. The
  ## states never mix: each one is judged exactly as it would have been alone,
  ## which is why records are not packed into a shared state here.
  ##
  ## A state whose request fails is parked - its error is stored and raised when
  ## one of its judgments is read - so one bad record does not kill the run.
  result = newSeq[Answers](batches.len)
  var payloads = newSeq[JsonNode](batches.len)
  var keys = newSeq[string](batches.len)
  var pending: seq[int]

  template park(i: int, err: ref JevError) =
    result[i] = Answers(model: batches[i].model,
                        unresolvable: batches[i].unresolvable, failure: err)

  for i in 0 ..< batches.len:
    try:
      if batches[i].sites.len == 0:
        result[i] = c.noQuestions(batches[i])
      else:
        let p = c.prepare(batches[i])
        payloads[i] = p.payload
        keys[i] = p.key
        if p.local.isNil: pending.add i
        else: result[i] = c.finish(batches[i], p.payload, p.local, p.key, p.source)
    except JevError as e:
      park(i, e)

  var bodies = newSeq[JsonNode](batches.len)
  var errs = newSeq[ref JevError](batches.len)
  c.postMany(pending, payloads, c.inFlight, bodies, errs)
  for i in pending:
    if errs[i].isNil:
      try: result[i] = c.finish(batches[i], payloads[i], bodies[i], keys[i], "live")
      except JevError as e: park(i, e)
    else:
      park(i, errs[i])

  # One deferred pass, one at a time. `postAsync` already retried in place, but a
  # 429 is collective - our own concurrency provoked it - so those attempts were
  # spent on the congestion that caused them. Running the survivors alone, after
  # the wave has drained, is a different attempt rather than a fifth identical
  # one.
  # ponytail: one pass, not a loop. A second only if a real workload shows the
  # first one converging.
  var again: seq[int]
  for i in 0 ..< batches.len:
    if result[i].failure.retryable: again.add i
  for i in again:
    try: result[i] = c.submit(batches[i])
    except JevError as e: park(i, e)

  if c.recordTo.len > 0: c.flushRecord()
  if c.trace:
    var parked = 0
    for a in result:
      if not a.failure.isNil: inc parked
    stderr.writeLine "runAll -> " & $batches.len & " state(s), " & $pending.len &
      " request(s) at " & $max(1, c.inFlight) & " in flight, " & $again.len &
      " rescheduled, " & $parked & " parked"
