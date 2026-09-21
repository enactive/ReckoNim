## Focus-path resolution against the snapshot.
##
## Jev does not report a bad `inspect` path - it falls back to judging the whole
## state and answers confidently about the wrong subject (measured: 0.92 for a
## missed path sitting beside a loud unrelated field). Nothing in the response
## distinguishes that from a correct answer, so these paths must never be sent.

import std/[json, os, strutils, tables]
import reckonim

delEnv("RECKONIM_RECORD")
delEnv("RECKONIM_REPLAY")

var requests: seq[JsonNode]

proc install(noul = 0.94) =
  requests = @[]
  globalClient = newClient(apiKey = "x", transport = proc (p: JsonNode): JsonNode =
    requests.add p
    var res = newJObject()
    for qid, q in p["questions"]:
      res[qid] = %*{"type": "noul", "noul": noul}
    %*{"model": "jev-1.13.0", "answers": res,
       "usage": {"input_tokens": 400, "output_tokens": 50}})

# ---------------------------------------------------------------- the resolver

let state = %*{
  "message": "hi",
  "items": [{"note": "fine"}],
  "empty": [],
  "customer": nil,
  "account": {"plan": "enterprise"},
  "meta": {"region": "eu"},
  "count": 3}

proc ok(path: string) = doAssert resolveFocus(state, path) == "", path & " -> " & resolveFocus(state, path)
proc bad(path, fragment: string) =
  let why = resolveFocus(state, path)
  doAssert why.len > 0, path & " should not resolve"
  doAssert fragment in why, "for `" & path & "` wanted '" & fragment & "', got: " & why

block resolvable_paths:
  ok ""                       # receiver is the state
  ok "message"
  ok "account.plan"
  ok "items[0]"
  ok "items[0].note"
  ok "meta.region"
  ok "empty"                  # the collection itself, not an element
  ok "count"

block every_failure_mode_is_caught:
  bad "items[1]", "out of range"          # index past end
  bad "empty[0]", "out of range"          # the guarded-empty-collection hazard
  bad "customer", "is null"               # nil ref serialized to null
  bad "customer.plan", "is null"          # ... and a field under it
  bad "account.missing", "has no field"   # missing key
  bad "nosuch", "has no field"            # absent at the root
  bad "message.sub", "is a string"        # not an object
  bad "count[0]", "cannot be indexed"     # not indexable
  bad "meta[region]", "rather than bracket indexing"   # object, not array

block error_names_the_available_fields:
  let why = resolveFocus(state, "account.nope")
  doAssert "plan" in why                  # tells you what is actually there

block root_prefixed_paths_are_accepted:
  # `compare` entries are written root-prefixed in the docs while `inspect` is
  # state-relative; the service accepts both, so neither may be rejected.
  doAssert resolveFocus(state, "order.account.plan", "order") == ""
  doAssert resolveFocus(state, "account.plan", "order") == ""
  doAssert resolveFocus(state, "order.account.nope", "order").len > 0

# ---------------------------------------------------------------- what actually ships

block paths_are_read_from_the_instructions_not_the_bookkeeping:
  # The hole this closes: `focusPath` is ReckoNim's own record, but the service
  # follows `inspect`. Validating only the former leaves hand-built structured
  # instructions unguarded.
  doAssert focusPathsIn(%*{"inspect": "a.b", "question": "q"}) == @["a.b"]
  doAssert focusPathsIn(%*{"question": "q", "compare": ["x.y", "x.z"]}) == @["x.y", "x.z"]
  doAssert focusPathsIn(%*"a plain string question").len == 0
  doAssert focusPathsIn(nil).len == 0

block divergent_inspect_is_still_caught:
  var b = initBatch("order", state)
  let id = b.add QuestionSite(
    slug: "sneaky", stateRoot: "order",
    focusPath: "",                                   # bookkeeping says "the state"
    primitive: pNoul,
    instructions: %*{"inspect": "account.nonexistent",   # what actually ships
                     "question": "Is this high value?"})
  doAssert b.sites.len == 0
  doAssert id in b.unresolvable
  doAssert "has no field" in b.unresolvable[id]

block bad_compare_path_is_caught:
  var b = initBatch("order", state)
  let id = b.add QuestionSite(
    slug: "cmp", stateRoot: "order", focusPath: "", primitive: pNoul,
    instructions: %*{"question": "Do these conflict?",
                     "compare": ["account.plan", "account.missing"]})
  doAssert id in b.unresolvable
  doAssert "missing" in b.unresolvable[id]

block good_compare_paths_pass:
  var b = initBatch("order", state)
  discard b.add QuestionSite(
    slug: "cmp", stateRoot: "order", focusPath: "", primitive: pNoul,
    instructions: %*{"question": "Do these conflict?",
                     "compare": ["account.plan", "order.meta.region"]})
  doAssert b.sites.len == 1                          # mixed conventions, both fine
  doAssert b.unresolvable.len == 0

# ---------------------------------------------------------------- through the macro

type
  Item = object
    note: string
  Order = object
    message: string
    items: seq[Item]

block unreached_bad_judgment_is_harmless:
  # The speculation invariant: hoisting must not change program behaviour. The
  # inner judgment is hoisted into the batch, its path misses, and control flow
  # never reaches its site - so the program must run to completion. Note that an
  # `if` *reads* the judgment through the converter; reading is what raises.
  install(noul = 0.02)                             # the outer condition is false
  let order = Order(message: "all good", items: @[])
  var reached = false
  withState order:
    if order.message.feels "Is this urgent?":
      if order.items[0].note.feels "Is this item defective?":
        reached = true
  doAssert not reached
  doAssert requests.len == 1
  doAssert requests[0]["questions"].len == 1        # only the resolvable one went

block reached_bad_judgment_raises:
  install()
  let order = Order(message: "all good", items: @[])
  var raised = false
  try:
    withState order:
      if order.items[0].note.feels "Is this item defective?":
        discard
  except UnresolvablePathError as e:
    raised = true
    doAssert "out of range" in e.msg
    doAssert "items" in e.msg
    doAssert "test_focus.nim:" in e.msg             # names the site
  doAssert raised

block bad_path_never_reaches_the_wire:
  install()
  let order = Order(message: "all good", items: @[])
  withState order:
    let defective {.used.} = order.items[0].note.feels "Is this item defective?"
    if order.message.feels "Is this urgent?": discard
  doAssert requests[0]["questions"].len == 1        # only the resolvable one
  for qid, q in requests[0]["questions"]:
    doAssert q["instructions"]["inspect"].getStr == "message"

block all_bad_means_no_request_at_all:
  install()
  let order = Order(message: "all good", items: @[])
  withState order:
    let a {.used.} = order.items[0].note.feels "Is this item defective?"
    let b {.used.} = order.items[1].note.feels "Is this one defective?"
  doAssert requests.len == 0                        # nothing worth asking

block resolvable_index_still_batches:
  # The fix must not cost batching for paths that do resolve.
  install()
  let order = Order(message: "x", items: @[Item(note: "a"), Item(note: "b")])
  withState order:
    if order.items[0].note.feels "Is this defective?": discard
    if order.items[1].note.feels "Is this defective?": discard
    if order.message.feels "Is this urgent?": discard
  doAssert requests.len == 1
  doAssert requests[0]["questions"].len == 3

block session_reports_drops:
  install()
  let order = Order(message: "x", items: @[])
  let s = newSession(globalClient, "order", %order)
  discard s.feels("items[0].note", "Is this defective?")
  discard s.feels("message", "Is this urgent?")
  doAssert s.pending == 1
  doAssert s.dropped == 1
  s.run()
  doAssert requests[0]["questions"].len == 1

echo "ok"
