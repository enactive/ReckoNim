## Must not compile: the focus path does not resolve against the state's type.
## Jev returns a meaningless number for this rather than an error (measured:
## a nonexistent path returned 0.43), so the compiler is the only line of defence.
## Expected message mentions "does not resolve in state".
import reckonim

type
  Account = object
    plan: string
  Ticket = object
    message: string
    account: Account

let ticket = Ticket(message: "hi", account: Account(plan: "enterprise"))

withState ticket:
  if ticket.account.nonexistentField.feels "Is this risky?":
    discard
