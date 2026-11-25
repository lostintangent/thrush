# Terminal pane lifecycle

A `TerminalSession` owns a terminal and its scrollback. The app keeps it when a tab moves out of view and observes `hasEnded` to decide what to do when the shell ends. The pane keeps the screen and history readable and copyable through interruptions and after exit.

## Opening and reconnecting

A small spinner at the terminal cursor is the only visual indication of opening or reconnecting. Before the first prompt it occupies the initial cursor cell. On a lost WebSocket it uses the last confirmed cursor position. Show the spinner after 200 ms. Its spokes use the cursor color in active and inactive windows, with a contrasting fallback against the cell beneath it. It stays still with Reduce Motion and is labeled “Connecting” or “Reconnecting” for VoiceOver. Announce “Reconnecting” once when an interruption reaches that delay. Keep the grid, selection, keyboard focus and VoiceOver reading position in place.

During an ordinary reconnect, hold committed text, paste and keys in order. IME preedit stays local. After `ready(resumed: true)`, wait for the binary replay to restore the shell’s input modes, then send held input once. The restored shell controls what appears as echo.

## Another window takes the shell

When another WebSocket attachment takes ownership, keep the last screen and stop automatic retries. A deliberate tap in the terminal requests ownership without sending terminal bytes. A keystroke also requests ownership and is held until the same shell resumes. Further input follows it in order. Scrolling, selection, copying, focus changes and foreground return leave the other window in control.

## The server starts a replacement shell

A fresh ready on reattach means the old shell expired. Keep its main screen in scrollback, with the earlier history, and leave the alternate screen behind. Start the replacement at row one with fresh modes and title. Discard held input intended for the old shell. The same session immediately accepts input and `hasEnded` stays false. Announce “New shell” once.

## The shell ends

Apply the last output before reporting exit. When the shell exits or the app closes it, the session sets `hasEnded` and the pane stays available for reading. The app owns any dismissal or action to start another shell. Starting one requires a new `TerminalSession`. The pane announces “Shell ended” once when the shell ends. Reopening a finished tab leaves VoiceOver’s reading position alone.

## In-band replay

When a WebSocket reader falls behind, the server can send `ready(resumed: true)` on the same socket. Keep accepting input and displaying the current screen until the session applies the next binary message as a replay. Present the restored screen in one frame. The cursor spinner stays off during an in-band replay.

- At the live edge, follow the restored cursor. In history, preserve the top logical line and its offset through soft wraps. Match text and neighboring lines across the reset, since row numbers can change. If the line has expired, use its nearest identifiable surviving neighbor, falling back to the oldest retained line.
- Keep an active selection and its handles only when both endpoints and the intervening text identify the same logical range. Reposition the handles for the new cell geometry. If the range is absent or ambiguous, clear the selection and its edit menu. Copy always reads the displayed generation.
- Keep the native marked string, its internal selection and the same input responder. Move the composition to the restored cursor when the frame swaps. Replay sends no composition bytes. The user’s eventual commit goes to the still-active shell exactly once.

## Check on Mac and iPhone

Open a shell, interrupt a WebSocket while typing and check the spinner at the cursor. Verify that the grid holds its size and a resumed Vim receives the held key in its restored mode. Displace the shell from another window and confirm that reading or foregrounding either pane leaves ownership alone. Reclaim once by tapping and once by typing. The tap sends no terminal bytes and the triggering key reaches the same shell exactly once.

Let an orphan expire with input held. Verify that the replacement prompt starts at row one, the previous main screen is readable in history and the replacement receives only new input. On natural exit, copy the final line and check that the app can dismiss the tab or present a new session in the same pane. A new session starts with a fresh screen and history. With VoiceOver enabled, the reading position stays on terminal content throughout.
