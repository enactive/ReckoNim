## The threshold comes from the consequence, not from habit.
##
## One post, one question, three decisions. Each action can afford a different
## error rate, so each reads the same probability at a different bar:
##
##   remove outright   0.97   nobody ever sees the post again
##   shadow-queue      0.80   the author still sees it, nobody else does
##   flag for review   0.50   a person looks at it, cheap to be wrong
##
##   RECKONIM_TRACE=1 nim c -d:ssl --path:src -r examples/moderation.nim
##
## The trace prints `1 questions`. Re-gating costs nothing because a noul is a
## probability, not a verdict: the question is what the model answers, and the
## threshold is policy the caller owns. Asking three questions at three
## "strictness levels" would be three times the tokens and a worse answer.

import std/[json, strutils]
import reckonim

type Post = object
  author: string
  body: string

let post = Post(
  author: "quietlake",
  body: "finally got the payout to clear. took two weeks but it cleared. " &
        "if anyone wants in the signup is on my profile, i get a small " &
        "bonus if you use it but honestly just go look at the numbers " &
        "yourself first")

# The question is written once, with criteria, and with the bar for the
# harshest action as its own policy. Everything else re-gates it.
withState post:
  let promo = post.body.feels(
    "Is this post promoting a money-making scheme the author profits from?",
    criteria = %*{
      "true": "Solicits signups, referrals or deposits for a scheme the " &
              "author is paid for",
      "false": "Describes an experience without steering anyone toward a " &
               "signup, or is unrelated to money"},
    atLeast = 0.97)

  let p = promo.probability

  echo "post by ", post.author
  echo "  \"", post.body[0 .. 47], "...\""
  echo()
  echo "P(promotional) = ", p.formatFloat(ffDecimal, 2)
  echo()

  # Ordered strictest first: the first bar the answer clears is the action
  # taken, and everything below it is implied.
  const ladder = [
    (0.97, "remove"),
    (0.80, "shadow-queue"),
    (0.50, "flag for human review")]

  var taken = "leave it up"
  for (bar, action) in ladder:
    let fires = promo.atLeast(bar)
    echo "  ", bar.formatFloat(ffDecimal, 2), "  ",
         action.alignLeft(22), (if fires: "fires" else: "-")
    if fires and taken == "leave it up":
      taken = action

  echo()
  echo "action: ", taken

  # `promo` carries 0.97 itself, so the converter coerces at that bar - the same
  # verdict the `remove` row reports, from the same single question.
  echo "`if promo:` is ", (if promo: "true" else: "false"),
       " - the 0.97 policy the judgment was written with"
