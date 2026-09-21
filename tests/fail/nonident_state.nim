## Must not compile: withState needs a plain identifier - `withState X` means
## literally "X is the Jev state". Combined state is built explicitly.
## Expected message mentions "plain identifier".
import std/json
import reckonim

let ticket = %*{"message": "hi"}

withState (a: ticket, b: 1):
  if ticket.message.feels "Is this urgent?":
    discard
