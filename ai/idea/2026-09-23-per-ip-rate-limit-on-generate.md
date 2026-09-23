# Per-IP rate limit on `/api/generate`

There is no rate limiting. `maxConcurrent` (default 4) gates simultaneous jobs,
but one client can keep all four slots busy back-to-back, each burning up to
`timeoutSeconds` of CPU — enough to make the service unresponsive for everyone
during the talk without tripping any limit.

Not a correctness or isolation problem (the sandbox and the per-job prlimits
still hold), just availability, and nobody is waiting on it — hence an idea, not
a todo. For a two-day window it may not be worth the code.

## If done

Cheapest is at the edge: caddy `rate_limit` (needs the
`caddy-ratelimit` plugin, so a custom caddy build) or a token-bucket WAI
middleware keyed on the peer address in `module.nix`'s reverse-proxy path.
Remember `reverseProxy.enable = false` deployments bypass caddy, so an
app-level middleware is the more general home — but then it must read the real
client IP from `X-Forwarded-For` only when behind a trusted proxy, not the
socket peer.
