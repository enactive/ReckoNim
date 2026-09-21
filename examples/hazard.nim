## The hazard, against the live service.
##
## `inspect` is a hint, not a selector. When the path misses, Jev judges the
## whole state and answers confidently about the wrong subject. Here the account
## is a nil ref, so `account.plan` cannot resolve, while a sibling field shouts
## about an enterprise plan. Raw Jev returns ~0.9 - indistinguishable from a
## correct answer. ReckoNim never sends it.
##
##   nim c -d:ssl --path:src -r examples/hazard.nim

import std/[json, strutils, httpclient, os]
import reckonim

type
  Account = ref object
    plan: string
  Order = object
    account: Account
    note: string

let order = Order(account: nil,
                  note: "THE PLAN IS ENTERPRISE, EXTREMELY HIGH VALUE")

echo "state: ", $(%order)
echo()

echo "--- raw Jev, path `account.plan` does not resolve:"
# Posted directly. ReckoNim will not construct this request - that is the point -
# so the unguarded behaviour has to be shown by going around it.
block:
  let http = newHttpClient(timeout = 30_000)
  defer: http.close()
  http.headers = newHttpHeaders({
    "Authorization": "Bearer " & getEnv("JEV_API_KEY"),
    "Content-Type": "application/json"})
  let body = parseJson(http.request(DefaultEndpoint, HttpPost, body = $(%*{
    "state": %order,
    "model": DefaultModel,
    "questions": {"high_value": {
      "type": "noul",
      "instructions": {"inspect": "account.plan",
                       "question": "Is this a high-value plan?"}}}})).body)
  echo "  noul = ", body{"answers", "high_value", "noul"}.getFloat,
       "   <- confident, and about the wrong subject"
echo()

echo "--- through ReckoNim:"
withState order:
  let highValue = order.account.plan.feels "Is this a high-value plan?"
  if order.note.feels "Is this note shouting?":
    echo "  the resolvable judgment answered normally"
  try:
    discard highValue.probability
    echo "  BUG: a judgment with an unresolvable focus path returned a value"
  except UnresolvablePathError as e:
    echo "  refused: ", e.msg.split(": ", 1)[1]
