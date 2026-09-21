## Must not compile: `reply` is not rooted at `ticket`, so it is a different Jev
## state and needs its own block. Expected message mentions "not rooted at state".
import std/json
import reckonim

let ticket = %*{"message": "hi"}
let reply = "We have escalated this."

withState ticket:
  if ticket.message.feels "Is this urgent?":
    if reply.feels "Is this reply appropriate?":
      discard
