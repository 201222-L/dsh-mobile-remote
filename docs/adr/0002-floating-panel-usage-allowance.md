# Floating panel usage and allowance

Status: accepted

The floating bubble panel shows the full usage and allowance projection in place of its single DeepSeek balance row, and falls back to that row whenever the projection is unavailable. The native service fetches the projection once per panel open under a client-side throttle rather than joining the thirty-minute background and five-second panel cadences that already serve the balance row, because opening a panel is user-initiated: this keeps the "no periodic upstream polling" expectation intact while still showing allowance when the app is not running.

Only monetary balances take part in low-balance alerting; time-window quotas are shown but never light the bubble or borrow the balance wording, because quota cannot be topped up. Account identity stays off the overlay, which is visible over other apps and on the lock screen, though the app detail view still names the active Codex account. Balances and quota windows are never summed, the panel renders remaining capacity as bars and colour without percentages or amounts, and additional Codex buckets stay in the app detail view, where they can be labelled.

## Considered options

- Reusing the five-second panel refresh was rejected: the projection is not cached when any source fails, so that cadence would fan out to three providers every five seconds.
- Reading a server-side snapshot without allowing a fetch was rejected: the snapshot lives sixty seconds, so the panel would be empty almost always.
- Rendering a bar for a monetary balance was rejected: a balance has no natural denominator, and using the alert threshold as one would silently redefine a reminder as a scale.
