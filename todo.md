# OgEx TODO

## Request coalescing

Prevent concurrent cache misses for the same image key from rendering the same
card more than once.

Proposed implementation:

- Add `OgEx.SingleFlight`, a lightweight coordinator keyed by the complete
  renderer cache key.
- Run image generation under an `OgEx.TaskSupervisor` so unrelated cards render
  concurrently and the coordinator never performs CPU-heavy work.
- Let the first caller start the render and hold subsequent callers for that
  key until it completes.
- Perform a second cache lookup after entering the flight to close the race
  between the initial miss and flight registration.
- Reply to every waiter with the same success or failure result.
- Cache only successful encoded images; allow later requests to retry failures.
- Monitor render tasks and return a structured error to all waiters if a task
  crashes.
- Add concurrency tests proving that one render occurs for simultaneous
  identical keys while different keys still render in parallel.

This initially provides single-flight behavior within one BEAM node. Distributed
coalescing can remain the responsibility of a future shared-cache adapter or
distributed lock implementation.
