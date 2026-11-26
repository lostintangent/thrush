# Rendering

The pane draws terminal state with Metal. This document covers how shell output reaches a frame and when that frame draws. [The rendering benchmarks](../Benchmarks/rendering.md) measure the result.

## From output to a frame

The session reads shell output on its own actor and never waits for the view. After each read, it applies the bytes to its `Terminal` and offers the screen snapshot to the pane's `OutputMailbox`. The new snapshot replaces any snapshot still waiting there, and at most one wakeup to the main actor is queued at a time. The frame takes whatever is waiting just before Metal encodes the grid, so it shows everything that arrived before it started. A frame's receipt time comes from the first update it includes, so latency counts from the oldest output on screen.

Some updates have to arrive in order rather than as the latest snapshot. These are the start and end of synchronized output, replay, shell replacement and exit. The pane presents any waiting output before it applies one of them.

## When a frame draws

A program often writes one change in several pieces a fraction of a millisecond apart, such as a clear followed by the next prompt. A frame drawn between two pieces shows half the change for a whole refresh. So `FramePacer` draws program output once per display refresh, after its writes pause, and as late as still makes that refresh. Echo takes the same path, so it reaches the screen on the refresh an immediate draw would have made.

```
refresh N-1                                                     refresh N
    │                                                                │
    │   output    output                                             │
    │     ▼         ▼                                                │
    ├─────┼─────────┼────────────┬──────────┬────────────────────────┤
    │                            ├── hold ──┤◀──────── margin ──────▶│
    │                         earliest   deadline                    │
    │                                                                │
    │   The frame draws 0.5 ms after the last output, but no earlier │
    │   than the hold and never after the deadline.                  │
```

`FramePacer.Schedule` holds the rules as a pure value that the pacer feeds with display link ticks and frame costs.

- **The refresh grid.** Each display link tick reports when its refresh will show. The schedule averages the interval over every refresh since it last lost the beat. That lets it predict refreshes on the display's own cadence while the link is paused. A new refresh rate, such as ProMotion changing speed, starts a new measurement.
- **The deadline.** A frame must start `margin` before its refresh. The margin is the slowest recent frame's cost plus 1 ms for the timer's wakeup and for the compositor to pick up the finished frame. It never takes more than three quarters of a refresh. A frame's cost runs from when it was due until its GPU work ends. A slower frame raises the cost at once, and faster frames bring it back down by an eighth each.
- **The quiet window.** The frame draws once output has paused for 0.5 ms. It never draws earlier than `hold` before the deadline, which is 2 ms or a quarter of a refresh, whichever is shorter. It never draws later than the deadline either. Pieces written less than 0.5 ms apart share a frame unless they straddle the deadline. A single write such as an echo draws within 0.5 ms or at the start of the hold, and both come before the deadline.
- **One frame per refresh.** The compositor shows each frame for at least one refresh. A second frame for the same refresh would show a refresh late, so output that arrives after a frame drew waits for the next refresh.

One strict dispatch timer on the main queue wakes the pacer at the draw time. It runs on the same host clock as `CACurrentMediaTime`. If more output arrives before the timer fires, the pacer moves the timer later, within the same deadline. If the main thread was busy past the draw time, the next tick draws at once. Before the link has reported its first refresh, such as for the first output after the view joins a window, the view draws immediately.

The pacer owns the view's only display link and runs it only while something needs ticks. Output needs them until the first refresh after it arrives, which keeps the grid current. Blinking text needs them during its fades, at 30 to 60 Hz because an opacity fade looks smooth at 60 Hz. A view that's idle, hidden or outside a window has no running link or timer and draws nothing.

Changes the user or the app makes, such as resizing, scrolling, selecting, focus or a theme, draw on MetalKit's next display pass without the pacer. So does each step of a blink fade.
