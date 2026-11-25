# Terminal protocol

A shell occupies a pseudoterminal on the server. A WebSocket carries its byte stream to a pane. The host chooses the server, authenticates the connection and supplies a stable client ID for each shell tab. Every control below is a complete UTF-8 JSON text message. Each binary message carries raw terminal bytes.

## Attach

Open a WebSocket at `/socket?service=terminal&clientId=ID&cols=C&rows=R`. Percent-encode the client ID as a query value. The size is in character cells, with at least two columns and one row. In a hosted service, scope client IDs to the authenticated user. A UUID works well for a new tab.

| Sender | Message | Receiver action |
| --- | --- | --- |
| Server | `{"type":"ready","resumed":false}` | Start with a blank terminal at the requested size. Apply all following binary output in order. |
| Server | `{"type":"ready","resumed":true}` | Apply the **next binary message** as one VT repaint to a fresh terminal at the negotiated size. Then apply subsequent output. An empty screen still gets a replay message. |
| Server | Binary | Feed bytes to the terminal. A UTF-8 character or VT sequence can span messages. |
| Client | Binary | Write to the PTY in order. This includes typed input, paste and replies to terminal queries. |
| Client | `{"type":"resize","cols":80,"rows":24}` | Resize the PTY and its retained terminal to the same grid so the program can redraw. |
| Client | `{"type":"close"}` | End the shell and its PTY. A later attachment with this ID gets a fresh shell. |
| Server | `{"type":"exit"}` | Keep the final screen, mark the shell ended, then accept the normal WebSocket close (1000). Send all final binary bytes before exit. |

A WebSocket closing without a terminal `close` message detaches the pane. The server retains the live shell for 30 seconds. Reattaching with the same ID inside that window cancels expiry and returns a resumed ready and replay. If the shell has exited or the deadline has passed, the server starts a new one and returns fresh ready. A concurrent attachment with the same ID takes ownership and closes the previous socket with code 4000. The displaced pane waits for an explicit **Use Here** action. Only the owning socket can write, resize or close the shell.

The client delays a resize requested during attach until the initial replay is complete. It sends held keystrokes only after a resumed ready and its replay restore the shell’s input modes. A fresh ready discards held input from the previous shell.

## Replay

The repaint is ordinary VT output. It describes both buffers, retained history, soft wraps, cells and their styles, window title, the colors the program set, cursor and input modes. The server tracks output even while detached. If a socket or PTY read ended partway through a UTF-8 character or control, the repaint ends with the corresponding unfinished prefix, including the payload so far of an unfinished title or color command. The next live bytes complete it once. A client’s local theme supplies every color the program hasn't set.

Two resize effects cannot be addressed by VT output at the current grid size.

- A shrink can leave a wide glyph straddling the right edge. At four columns the uninterrupted model retains `中` in the fourth cell of `abc中` and `DEF中`. The repaint leaves that cell blank in each row. When reflow widens those rows, the model can carry a character underneath the second half of the wide glyph. A repaint uses a continuation cell there. The glyph still draws across both cells.
- An alternate screen can keep columns outside its viewport. Shrinking `left + right` from twelve columns to six gives `left +` in both the live and restored screen. Widening the uninterrupted screen can reveal ` right`. The restored screen has six blank columns there until the program redraws.

A slow reader can miss individual live writes. The bundled server stops sending live output when the next write would exceed **1 MiB of outstanding live bytes** or when 256 WebSocket messages are outstanding. The server continues parsing PTY output. Once the outstanding writes drain, it sends a resumed ready and one repaint on the **same socket**, even if the program has gone quiet. An exiting shell sends the final repaint before exit. The pane keeps its previous screen on display until the repaint arrives. A repaint recovers the current screen and up to 1,000 history rows. Anyone needing a log of every output byte must record the PTY stream at the server.

## Run a server

From a Thrush checkout on macOS, run the following command. It uses the Swift toolchain and system frameworks, binds to `127.0.0.1:9138` and prints its URL.

```sh
swift run ThrushServer
```

The default shell is `/bin/zsh`. It starts in a new working directory with a private home, temporary directory and a system `PATH`. Stop the server with Control-C to release its shells and remove its temporary workspace. To keep the workspace for inspection, supply a new or empty directory. Port zero asks the OS to choose a free port.

```sh
swift run ThrushServer --port 0 --shell /bin/bash --data-dir ./shell-run
```

The bundled server accepts grids from 2–512 columns and 1–256 rows, up to 16 concurrent shells and client IDs up to 128 UTF-8 bytes. Each incoming input message is bounded to 1 MiB. A serialized replay can be up to 64 MiB. A host that supplies its own `URLSessionWebSocketTask` can set `maximumMessageSize` to that limit for large, heavily styled histories. A repaint exceeding the transfer limit ends the attachment with WebSocket code 1009.

See the [sample app commands](demo.md), [real PTY checks](../Benchmarks/pty.md) and [native workflow checks](../Benchmarks/live-workflows.md).
