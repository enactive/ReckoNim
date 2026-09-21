## ReckoNim - judgments and their results. See PLAN.md section 7.
##
## A judgment is written where it is needed, but cannot be answered there: the
## whole point is that it travels with its siblings in one request. So `feels`,
## `choice` and `score` return an *unresolved* handle, `run` sends the batch, and
## the handle reads its answer afterwards. Reading one early raises.
##
## Phase 3's macro generates exactly this shape from `withState`. Everything here
## is usable without it, which is what makes it testable on its own.

import std/[json, tables]
import ./jev
export tables ## `probabilities` returns an OrderedTable; iterating it needs this.

type
  Session* = ref object ## One `withState`: one state, one batch, one request.
    client*: Client
    batch*: Batch
    answers*: Answers
    resolved*: bool

  Judgment*[T] = object
    session: Session
    id*: string
    site*: QuestionSite
    threshold: float ## noul only; a coercion policy, not part of the question

  UnresolvedError* = object of JevError ## read before `run`

var defaultThreshold* = 0.5
  ## The neutral point for a noul: 0.5 means yes and no are equally likely. It
  ## does not mean "moderately confident" - a noul carries no confidence.
  ## Per confidence.md, a real threshold is chosen per action, by consequence.

# ---------------------------------------------------------------- session

proc newSession*(client: Client, stateRoot: string, state: JsonNode,
                 model = DefaultModel): Session =
  Session(client: client, batch: initBatch(stateRoot, state, model))

proc add(s: Session, site: QuestionSite): string =
  if s.resolved:
    # `withEachState` fills every session, resolves them together, then runs the
    # bodies - where the same judgment sites are written a second time. An
    # identical site is already answered, so hand back its id. A site that is
    # genuinely new never would be.
    result = site.id
    if result in s.batch.sites or result in s.batch.unresolvable: return
    raise newException(UnresolvedError,
      "cannot add '" & site.slug & "' to state '" & s.batch.stateRoot &
      "' after run() - it would never be answered")
  s.batch.add site

proc run*(s: Session) =
  ## Send this session's questions as one request. Idempotent.
  if s.resolved: return
  s.answers = s.client.submit(s.batch)
  s.resolved = true

proc runAll*(sessions: seq[Session]) =
  ## Send many independent sessions' questions with several requests in flight.
  ## Each session keeps its own state and its own request - nothing is shared
  ## between them but the client.
  ##
  ## Only the requests overlap. Callers read the answers afterwards, one session
  ## at a time, on this thread; nothing a caller writes ever runs concurrently.
  var pending: seq[Session]
  for s in sessions:
    if not s.resolved: pending.add s
  if pending.len == 0: return

  var batches = newSeq[Batch](pending.len)
  for i, s in pending: batches[i] = s.batch
  let answers = pending[0].client.submitAll(batches)
  for i, s in pending:
    s.batch = batches[i]
    s.answers = answers[i]
    s.resolved = true

proc pending*(s: Session): int = s.batch.sites.len
  ## Distinct questions queued. Lower than the number of judgment sites when
  ## identical judgments deduplicated.

proc dropped*(s: Session): int = s.batch.unresolvable.len
  ## Judgments whose focus path missed in the snapshot, so they are not sent.
  ## Harmless until read; reading one raises UnresolvablePathError.

# ---------------------------------------------------------------- construction

proc mkSite(s: Session, slug, focusPath, question: string, prim: Primitive,
            criteria: JsonNode, loc: string): QuestionSite =
  QuestionSite(
    slug: (if slug.len > 0: slug else: slugify(question)),
    stateRoot: s.batch.stateRoot, focusPath: focusPath, primitive: prim,
    instructions: focusedInstructions(focusPath, question),
    criteria: criteria, sourceLocation: loc)

proc feels*(s: Session, focusPath, question: string, criteria: JsonNode = nil,
            atLeast = defaultThreshold, slug = "", loc = ""): Judgment[bool] =
  let site = s.mkSite(slug, focusPath, question, pNoul, criteria, loc)
  Judgment[bool](session: s, id: s.add(site), site: site, threshold: atLeast)

proc choice*(s: Session, focusPath, question: string, criteria: JsonNode,
             slug = "", loc = ""): Judgment[string] =
  let site = s.mkSite(slug, focusPath, question, pChoice, criteria, loc)
  Judgment[string](session: s, id: s.add(site), site: site)

proc score*(s: Session, focusPath, question: string, levels: JsonNode,
            slug = "", loc = ""): Judgment[float] =
  if levels.kind != JArray:
    raise newException(JevError, "score criteria must be an ordered list of levels, got " &
      $levels.kind & " - the service rejects maps here")
  let site = s.mkSite(slug, focusPath, question, pScore, levels, loc)
  Judgment[float](session: s, id: s.add(site), site: site)

# ---------------------------------------------------------------- reading

proc answers[T](j: Judgment[T]): Answers =
  if j.session.isNil or not j.session.resolved:
    raise newException(UnresolvedError,
      "judgment '" & j.id & "' read before run() - a judgment has no value " &
      "until its batch is sent")
  j.session.answers

proc probability*(j: Judgment[bool]): float =
  ## P(yes). This *is* the noul answer; there is no separate confidence.
  j.answers.noul(j.id)

proc value*(j: Judgment[bool]): bool =
  j.probability >= j.threshold

proc atLeast*(j: Judgment[bool], threshold: float): bool =
  ## One-off threshold without changing the judgment's own policy. Gate different
  ## actions at different levels; the question sent is identical either way.
  j.probability >= threshold

converter toBool*(j: Judgment[bool]): bool = j.value
  ## Makes `if ticket.message.feels "urgent":` compile while `.probability` stays
  ## reachable - PLAN.md section 7. An unanswered judgment raises here rather than
  ## coercing to false.

proc value*(j: Judgment[string]): string =
  ## The selected option, regardless of how flat the distribution is. Gating is
  ## the caller's decision - see `confidence`.
  j.answers.choice(j.id)

proc value*(j: Judgment[float]): float =
  ## The probability-weighted mean of level indices. NOT the most likely level;
  ## see `level`.
  j.answers.score(j.id)

proc level*(j: Judgment[float]): int =
  ## The most likely level, computed from the distribution. Never round `value`
  ## to get this - measured, {0:0.45, 1:0.1, 2:0.45} has mean 1.0 while no level
  ## 1 ever won.
  j.answers.level(j.id)

proc confidence*[T](j: Judgment[T]): float =
  ## Choice and score only. Raises for a noul rather than inventing a number.
  j.answers.confidence(j.id)

proc probabilities*[T](j: Judgment[T]): OrderedTable[string, float] =
  j.answers.probabilities(j.id)

proc legend*(j: Judgment[float]): JsonNode =
  j.answers.legend(j.id)

proc raw*[T](j: Judgment[T]): JsonNode =
  ## The answer exactly as returned, for provenance and trace output.
  j.answers.answer(j.id)
