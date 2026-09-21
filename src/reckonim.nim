## ReckoNim - probabilistic judgment layer for Nim over TypeSafe Jev.
##
## ReckoNim: write judgments where they are needed; the ones sharing a state
## travel in one Jev request. See PLAN.md.
##
##   withState ticket:
##     if ticket.message.feels "urgent": escalate(ticket)
##     if ticket.customer.feels "likely to churn": retain(ticket)

import reckonim/[jev, judge, withstate]
export jev, judge, withstate
