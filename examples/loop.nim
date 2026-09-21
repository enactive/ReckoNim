## A question inside a loop - what it costs, and the two ways out.
##
## usage-rules.md: "Avoid a question inside a loop. A runtime index makes one
## request per iteration today. Prefer one question whose focus path is the
## collection, or a literal index (`ticket.messages[1]`), which batches
## normally."
##
## This file is that rule, run twice over the same seq. The deliverable is the
## stderr trace:
##
##   RECKONIM_TRACE=1 nim c -d:ssl --path:src -r examples/loop.nim
##
## Pass 1 prints one `withState thread -> 1 request` line per comment. Pass 2
## prints one line, total.
##
## The cost is not N questions, it is N *requests*. A runtime focus path cannot
## be hoisted into the block's batch, so each iteration gets a fresh session and
## ships the entire state again alongside its ~30 tokens of question:
## N x (state + question), where the batched form is state + N x question. The
## `[... in / ... out]` counts on the trace lines are the receipt: measured on
## this 4-comment thread, pass 1 sends 4 x 441 = 1764 input tokens for 4
## questions, pass 2 sends 543 for 3. The gap is one copy of the state per
## extra iteration, and it grows with the state, not with the question.
##
## Note: todo #9 (batching judgments issued inside a loop) would make pass 1
## cost one request as well. If that lands this example is stale - rewrite it
## against the new cost, or delete it.

import std/[json, strutils]
import reckonim

type
  Comment = object
    author: string
    body: string
  Thread = object
    topic: string
    comments: seq[Comment]

let thread = Thread(
  topic: "changelog for v2.3",
  comments: @[
    Comment(author: "mel",
            body: "The migration note is missing. Anyone upgrading from 2.2 " &
                  "will lose their index."),
    Comment(author: "rob",
            body: "It is in the release post. Read it before filing noise."),
    Comment(author: "mel",
            body: "The release post is not the changelog. That is the whole " &
                  "point of having a changelog."),
    Comment(author: "rob",
            body: "Or you could try doing the work instead of auditing mine " &
                  "for once.")])

echo "thread: ", thread.topic, "  (", thread.comments.len, " comments)"
echo()

# --- pass 1: a judgment per iteration ---------------------------------------

echo "--- pass 1: runtime index inside the loop"
var hostile: seq[float]

withState thread:
  for i in 0 ..< thread.comments.len:
    # `comments[i]` is only known at runtime, so this judgment cannot join the
    # block's batch. It gets its own session, its own request, and its own copy
    # of the whole thread on the wire.
    hostile.add thread.comments[i].feels("Is this comment hostile?").probability

for i, p in hostile:
  echo "  ", thread.comments[i].author.alignLeft(6), p.formatFloat(ffDecimal, 2)
echo "  => ", hostile.len, " requests, ", hostile.len, " questions"
echo()

# --- pass 2: the collection is the focus path -------------------------------

echo "--- pass 2: one question over the collection, plus a literal index"

withState thread:
  # The receiver is the seq itself, so the focus path is constant and this is a
  # normal hoisted judgment.
  let anyHostile = thread.comments.feels(
    "Does any comment here attack a person rather than the work?")

  let heat = thread.comments.score(
    "How hostile has this thread become?",
    %*["Disagreement stated plainly",
       "Pointed, with jabs at the other person",
       "Open hostility or insults"])

  # A literal index is constant too, so it batches with the other two.
  let opener = thread.comments[0].feels "Is this comment hostile?"

  echo "  any hostile   ", anyHostile.probability.formatFloat(ffDecimal, 2)
  echo "  heat          level ", heat.level, " of 2  - ",
       heat.legend[$heat.level].getStr
  echo "  comments[0]   ", opener.probability.formatFloat(ffDecimal, 2)

echo "  => 1 request, 3 questions"
echo()
echo "Same seq, same subject. Pass 2 gives up the per-comment breakdown; that is"
echo "the trade, and it is usually the right one. When you need every record"
echo "judged separately, each record is its own state and its own withState."
