Mode: Cursor managed background completion supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Use the Cursor Shell tool to launch long-running `bin/fm-watch-arm.sh` as its own managed background task.
   Never bundle it with another command and never use shell &.
4. Treat `watcher: started ...` or `watcher: attached ...` as proof that one live cycle exists.
5. Let Cursor's managed background completion notification wake the session when that cycle returns.
6. On an ordinary completion wake, run `bin/fm-wake-drain.sh` first and handle the durable wake.
7. If supervision is still needed after handling the wake, start exactly one new managed background cycle.
8. A `watcher: FAILED ...` completion is an alarm.
   Drain first, investigate the failure, and repair with the same standalone Cursor managed background task.
9. Waiting on the managed cycle is silent.
10. The Stop hook is the final backstop when a needed cycle is missing or unhealthy.

Away mode keeps ownership through the shared `/afk` protocol instead of starting a normal Cursor cycle.
A read-only session never drains, starts, or repairs supervision.
