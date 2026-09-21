## ReckoNim - the `withState` macro. See PLAN.md sections 4 and 5.
##
## Purely syntactic. It derives a state-relative focus path by stripping the
## state root from each judgment's receiver, then emits the phase-2 Session calls
## that already work by hand. No new runtime semantics live here.
##
##   withState ticket:
##     if ticket.message.feels "urgent": escalate()
##     if ticket.customer.feels "likely to churn": retain()
##
## becomes one request with state = ticket and two questions.

import std/[macros, json, jsonutils, strutils]
import ./jev, ./judge
export jev, judge

var globalClient*: Client
  ## ponytail: one process-wide client, built lazily from JEV_API_KEY. Assign to
  ## override (the tests do). Per-session clients if anyone needs two endpoints
  ## at once.

proc activeClient*(): Client =
  if globalClient.isNil: globalClient = newClient()
  globalClient

proc toState*[T](x: T): JsonNode =
  ## The snapshot taken at block entry - PLAN.md section 15. Nothing later in the
  ## block can mutate what the judgments saw.
  when T is JsonNode: x
  # A named tuple is the documented way to judge several values against each
  # other (usage-rules hard rule 2), and std/json has no `%` for tuples.
  elif T is tuple: x.toJson
  else: %x

const JudgmentProcs = ["feels", "choice", "score"]

# ---------------------------------------------------------------- focus paths

type FocusPath = object
  parts: seq[NimNode] ## string-valued expressions, already carrying separators
  literal: string     ## valid only when `isLiteral`
  isLiteral: bool     ## a constant path may be hoisted; a runtime one may not
  rooted: bool

proc walkPath(n: NimNode, root: string, f: var FocusPath) =
  ## Peel `ticket.customer.account.plan` down to its root, collecting segments.
  case n.kind
  of nnkIdent, nnkSym:
    f.rooted = n.strVal == root
  of nnkDotExpr:
    walkPath(n[0], root, f)
    if not f.rooted: return
    let sep = if f.parts.len > 0: "." else: ""
    f.parts.add newLit(sep & n[1].strVal)
    if f.isLiteral: f.literal.add sep & n[1].strVal
  of nnkBracketExpr:
    walkPath(n[0], root, f)
    if not f.rooted: return
    # Arrays use bracket notation, measured to discriminate better than dots
    # (`messages[1]` -> 0.99 vs `messages.1` -> 0.94 on the same question).
    # A string key is an object field, which Jev writes dotted.
    if n[1].kind == nnkIntLit:
      f.parts.add newLit("[" & $n[1].intVal & "]")
      if f.isLiteral: f.literal.add "[" & $n[1].intVal & "]"
    elif n[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      let sep = if f.parts.len > 0: "." else: ""
      f.parts.add newLit(sep & n[1].strVal)
      if f.isLiteral: f.literal.add sep & n[1].strVal
    else:
      f.isLiteral = false
      f.parts.add newCall(ident"&", newLit("["),
                          newCall(ident"&", newCall(ident"$", n[1]), newLit("]")))
  else:
    f.rooted = false

proc focusOf(recv: NimNode, root: string): FocusPath =
  result = FocusPath(isLiteral: true, rooted: false)
  walkPath(recv, root, result)

proc expr(f: FocusPath): NimNode =
  ## `""` when the receiver *is* the state - `withState reply:` over a bare
  ## string emits no `inspect` key at all.
  if f.isLiteral: return newLit(f.literal)
  result = f.parts[0]
  for i in 1 ..< f.parts.len:
    result = newCall(ident"&", result, f.parts[i])

# ---------------------------------------------------------------- site matching

proc judgmentCall(n: NimNode): (bool, NimNode, string) =
  ## Matches `<recv>.feels(...)` / `.choice(...)` / `.score(...)` in both call and
  ## command form. Returns (matched, receiver, procName).
  if n.kind notin {nnkCall, nnkCommand} or n.len == 0: return (false, nil, "")
  let callee = n[0]
  if callee.kind != nnkDotExpr: return (false, nil, "")
  let name = callee[1]
  if name.kind notin {nnkIdent, nnkSym} or name.strVal notin JudgmentProcs:
    return (false, nil, "")
  (true, callee[0], name.strVal)

proc srcLoc(n: NimNode): string =
  let li = n.lineInfoObj
  li.filename.rsplit({'/', '\\'}, maxsplit = 1)[^1] & ":" & $li.line

# ---------------------------------------------------------------- rewriting

const StateMacros = ["withState", "withEachState"]

type Rewriter = object
  ## Shared by both macros. The only difference between them is `inline`.
  root: string
  sess, state: NimNode  ## the session and the state snapshot, in the emitted code
  prologue, guards: NimNode
  hoisted: int
  inline: bool
    ## false (`withState`): hoist each judgment into `prologue` and leave a symbol
    ## behind, because the batch and the body share one scope.
    ##
    ## true (`withEachState`): the batch is filled in one loop and the bodies run
    ## in a later one, so a symbol cannot bridge them. Emit the judgment twice -
    ## once into `prologue` to fill the batch, once in place to read it. The two
    ## are identical sites, so they carry one id and one question on the wire.

proc callFor(sess, focus: NimNode, call: NimNode, name, loc: string): NimNode =
  result = newCall(ident(name), sess, focus)
  for i in 1 ..< call.len: result.add call[i]
  result.add nnkExprEqExpr.newTree(ident"loc", newLit(loc))

proc rewrite(r: var Rewriter, n: NimNode): NimNode =
  # A nested block owns its own judgments; leave it to expand itself.
  if n.kind in {nnkCall, nnkCommand} and n.len > 0 and
     n[0].kind in {nnkIdent, nnkSym} and n[0].strVal in StateMacros:
    return n

  let (matched, recv, name) = judgmentCall(n)
  if matched:
    let f = focusOf(recv, r.root)
    let loc = srcLoc(n)
    if not f.rooted:
      error("`" & recv.repr & "." & name & "` is not rooted at state `" & r.root &
            "`. A judgment on another value is a different Jev state, so it needs " &
            "its own block:\n\n  withState " & recv.repr.split('.')[0] & ":\n    " &
            recv.repr & "." & name & "(...)\n\nTo judge both against one state, " &
            "build it explicitly:\n\n  let combined = (" & r.root & ": " & r.root &
            ", other: ...)\n  withState combined:\n", n)

    if f.isLiteral:
      # Constant focus path: hoist into the shared batch. Speculative, which is
      # Jev's own recommended pattern and costs no latency.
      if f.literal.len > 0:
        r.guards.add nnkWhenStmt.newTree(nnkElifBranch.newTree(
          nnkPrefix.newTree(ident"not", newCall(ident"compiles", recv)),
          nnkPragma.newTree(nnkExprColonExpr.newTree(ident"error", newLit(
            "focus path `" & f.literal & "` does not resolve in state `" & r.root &
            "` (" & loc & "). Jev does not report a bad path - it returns a " &
            "meaningless number - so this is checked here.")))))
      inc r.hoisted
      if r.inline:
        r.prologue.add nnkDiscardStmt.newTree(
          callFor(r.sess, f.expr, copyNimTree(n), name, loc))
        return callFor(r.sess, f.expr, n, name, loc)
      let sym = genSym(nskLet, "rkJ")
      r.prologue.add newLetStmt(sym, callFor(r.sess, f.expr, n, name, loc))
      return sym

    # Runtime focus path (a loop index). PLAN.md section 12: correct but
    # unbatched in the MVP - one request per evaluation. Batching these is an
    # additive macro change; the wire format already supports it.
    let s2 = genSym(nskVar, "rkSess1")
    let j2 = genSym(nskLet, "rkJ1")
    return nnkStmtListExpr.newTree(
      newVarStmt(s2, newCall(ident"newSession", newCall(ident"activeClient"),
                             newLit(r.root), r.state)),
      newLetStmt(j2, callFor(s2, f.expr, n, name, loc)),
      newCall(ident"run", s2),
      j2)

  result = copyNimNode(n)
  for child in n: result.add r.rewrite(child)

# ---------------------------------------------------------------- the macros

macro withState*(state: untyped, body: untyped): untyped =
  ## One state, one request. Judgments rooted elsewhere belong to a different
  ## `withState` - that is the protocol's rule, not a heuristic: the API accepts
  ## exactly one `state` per request.
  if state.kind notin {nnkIdent, nnkSym}:
    error("withState needs a plain identifier naming the state, got " & $state.kind &
          ". Bind it first: `let review = (ticket: ticket, reply: reply)`", state)

  var r = Rewriter(root: state.strVal,
                   sess: genSym(nskVar, "rkSess"), state: genSym(nskLet, "rkState"),
                   prologue: newStmtList(), guards: newStmtList())
  let newBody = r.rewrite(body)

  result = newStmtList(
    newLetStmt(r.state, newCall(ident"toState", state)),
    r.guards,
    nnkVarSection.newTree(nnkIdentDefs.newTree(
      nnkPragmaExpr.newTree(r.sess, nnkPragma.newTree(ident"used")),
      newEmptyNode(),
      newCall(ident"newSession", newCall(ident"activeClient"),
              newLit(r.root), r.state))),
    r.prologue)
  if r.hoisted > 0:
    result.add newCall(ident"run", r.sess)
  result.add newBody
  result = nnkBlockStmt.newTree(newEmptyNode(), result)

macro withEachState*(spec: untyped, body: untyped): untyped =
  ## Many independent records, one request each, several requests in flight.
  ##
  ##   withEachState ticket in tickets:
  ##     if ticket.message.feels "Is this urgent?": escalate(ticket)
  ##
  ## This is not a concurrency control - there is nothing here to tune. It is the
  ## statement that the records are independent and may be resolved in any order,
  ## which is a fact only the caller knows and so cannot be inferred from
  ##
  ##   for ticket in tickets:      # the body may depend on the previous
  ##     withState ticket:         # iteration, may break or return, and
  ##       ...                     # `tickets` may be an iterator
  ##
  ## Nothing else about the block changes. Each record is still its own state and
  ## its own request, judged exactly as it would have been alone - records are
  ## never packed into a shared state, because a judgment there moves with its
  ## neighbours. The bodies still run one at a time, on this thread, in order.
  ##
  ## A record whose request fails does not stop the others; its error is raised
  ## when one of its judgments is read.
  if spec.kind != nnkInfix or spec[0].strVal != "in":
    error("withEachState needs `item in collection`, as in " &
          "`withEachState ticket in tickets:`", spec)
  let item = spec[1]
  if item.kind notin {nnkIdent, nnkSym}:
    error("withEachState needs a plain identifier for the item, got " & $item.kind &
          ". Bind the collection first if it needs an expression.", item)

  let items = genSym(nskLet, "rkItems")
  let sessions = genSym(nskVar, "rkSessions")
  let it = genSym(nskForVar, "rkIt")
  let idx = genSym(nskForVar, "rkIdx")

  # One declaration each, reassigned per iteration, so both loops can name them.
  var r = Rewriter(root: item.strVal,
                   sess: genSym(nskVar, "rkSess"), state: genSym(nskVar, "rkState"),
                   prologue: newStmtList(), guards: newStmtList(), inline: true)
  let newBody = r.rewrite(body)

  # Loop one fills every batch; `runAll` sends them; loop two runs the bodies,
  # which rebuild the same judgments against their now-answered session.
  let build = nnkForStmt.newTree(it, items, newStmtList(
    newLetStmt(item, it),
    r.guards,
    newAssignment(r.state, newCall(ident"toState", item)),
    newAssignment(r.sess, newCall(ident"newSession", newCall(ident"activeClient"),
                                  newLit(r.root), r.state)),
    r.prologue,
    newCall(ident"add", sessions, r.sess)))

  let apply = nnkForStmt.newTree(idx,
    nnkInfix.newTree(ident"..<", newLit(0), newCall(ident"len", sessions)),
    newStmtList(
      newLetStmt(item, nnkBracketExpr.newTree(items, idx)),
      newAssignment(r.state, newCall(ident"toState", item)),
      newAssignment(r.sess, nnkBracketExpr.newTree(sessions, idx)),
      newBody))

  result = newStmtList(
    newLetStmt(items, spec[2]),
    nnkVarSection.newTree(nnkIdentDefs.newTree(
      sessions, newEmptyNode(),
      newCall(nnkBracketExpr.newTree(ident"newSeq", ident"Session")))),
    nnkVarSection.newTree(nnkIdentDefs.newTree(
      nnkPragmaExpr.newTree(r.sess, nnkPragma.newTree(ident"used")),
      ident"Session", newEmptyNode())),
    nnkVarSection.newTree(nnkIdentDefs.newTree(
      nnkPragmaExpr.newTree(r.state, nnkPragma.newTree(ident"used")),
      ident"JsonNode", newEmptyNode())),
    build)
  if r.hoisted > 0:
    result.add newCall(ident"runAll", sessions)
  result.add apply
  result = nnkBlockStmt.newTree(newEmptyNode(), result)
