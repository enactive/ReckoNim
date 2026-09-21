## Judging three values against each other - the tuple state.
##
## `withState` takes a plain identifier, because the state root is a name the
## macro strips off every receiver. A tuple literal has no name:
##
##   withState (diff: diff, message: message):   # error: needs a plain identifier
##
## Bind it first and the tuple becomes the state. That is not a workaround; it
## is the case the rule exists for. A commit message can only be judged against
## the diff it claims to describe, so both have to be in the same state, in the
## same request.
##
##   RECKONIM_TRACE=1 nim c -d:ssl --path:src -r examples/review.nim
##
## Five judgments, one request. Two are rooted at the tuple itself (no `inspect`
## key, so Jev reads the whole state); three narrow to `diff`.

import std/[json, strutils]
import reckonim

let diff = """
--- a/src/reckonim/jev.nim
+++ b/src/reckonim/jev.nim
@@ -418,9 +418,8 @@ proc post(c: Client, payload: JsonNode): JsonNode =
     if status in 200 .. 299:
-      try: return parseJson(body)
-      except CatchableError:
-        raise newException(JevProtocolError, "unparseable response body: " & body)
+      try: return parseJson(body)
+      except CatchableError: return newJObject()
"""

let message = "jev: tidy up response parsing"

let issue = """
#41 - client crashes on a truncated response
Reported twice under load. The stack ends in parseJson inside post().
"""

# The three values are one subject. Bind them, then judge them together.
let change = (diff: diff, message: message, issue: issue)

echo "commit: ", message
echo "issue:  ", issue.splitLines[0]
echo()

var notes: seq[string]

withState change:
  # Each judgment sits in the condition that uses it. All five leave in one
  # request before the first `if` is evaluated.
  if change.diff.feels(
       "Does this change touch error handling, authentication, or input validation?",
       criteria = %*{
         "true": "Adds, removes or alters a raise, catch, retry, permission " &
                 "check or validation",
         "false": "Touches none of those"}) and
     change.diff.score(
       "How far do the effects of this change reach?",
       %*["Local: one function, same behaviour for every caller",
          "Module-wide: changes a contract other code in the module relies on",
          "Cross-cutting: every caller of the library can observe the difference"]
     ).level >= 1:
    notes.add "needs a second reviewer: error handling, and the effect leaves the function"

  # Rooted at the tuple: the question is about the relationship between two of
  # its fields, so neither field alone is the right focus.
  if not change.feels(
       "Does the commit message describe what the diff actually does?",
       criteria = %*{
         "true": "The message names the behaviour the diff changes",
         "false": "The message is vaguer than the change, or describes " &
                  "something else"}):
    notes.add "rewrite the commit message to say what changed"

  # A missing test is only found by reading diff and issue together.
  if change.feels(
       "Does this change need a regression test that the diff does not add?",
       atLeast = 0.9):
    notes.add "add a regression test before merging"

  # Read twice - once to gate, once to report - so this one gets a name.
  let area = change.diff.choice(
    "Which area of the codebase does this change belong to?",
    %*{"core":  "Library logic, protocol, request or response handling",
       "tests": "Test files and fixtures only",
       "docs":  "README, comments, or documentation only",
       "build": "Packaging, CI, dependencies, or build configuration"})
  if area.confidence < 0.8:
    notes.add "area unclear (" & area.value & ") - route by hand"

echo "review"
if notes.len == 0:
  echo "  - nothing blocking"
for n in notes:
  echo "  - ", n
