# OpenCode v2 migration

This plugin now targets the native v2 CLI, TUI plugin SDK, and server API.
The Neovim commands, Snacks layouts, editor context, prompt expansion, and review
queue remain. OpenCode v1 users should pin plugin commit `aa2a146`.

The implementation was developed against OpenCode **2.0.1**, source
[`41e5d1b6`](https://github.com/anomalyco/opencode/tree/41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3).
The relevant contracts were also checked against the current v2 source on
2026-09-13,
[`195158c3`](https://github.com/anomalyco/opencode/tree/195158c34c4300d38b861fc4398de5f8cdb51d58).
The published SDK dependency is pinned for development typechecking. The bridge
has no runtime package dependencies; a normal plugin checkout is sufficient.

## Keep the external server workflow

The plugin connects to an existing server. It does not install OpenCode, start a
daemon, or own server lifetime. A supervisor can run the foreground server,
optionally inside a third-party sandbox:

```text
Supervisor -> optional sandbox -> opencode serve --hostname=127.0.0.1 --port=4096
Neovim -> Snacks terminal -> opencode --server http://127.0.0.1:4096 /project
```

Do not add `--service` inside that supervisor: it changes OpenCode's service
management rather than running the foreground process being supervised. The TUI
is a separate client process; tool execution runs in the server's environment.
Closing Neovim or its terminal does not stop the server.

V2 uses the primary `opencode` executable and existing configuration locations.
Follow the [official migration guide](https://opencode.ai/v2/docs/migrate-v1/)
and preserve a v1 backup before migrating. An adjacent executable alone does not
isolate state. Do not run v1 against already migrated data.

The generated TUI command uses a positional absolute directory, `--server`, and
optional `--continue` or `--session`. It no longer invokes `attach` or `--dir`.
A custom `terminal.cmd` is still an escape hatch and must itself launch a v2 TUI
against the intended server.

## Register the bridge in the client

Merge this into the writable global `~/.config/opencode/cli.json`:

```json
{
  "$schema": "https://opencode.ai/v2/cli.json",
  "plugins": ["/absolute/path/to/opencode.nvim"],
  "prompt": { "editor": true }
}
```

Use the absolute installation path, or the worktree path while testing. The
loader finds the root `tui.ts`; package exports alone are insufficient for a
local directory. V2 uses plural `plugins`, does not expand `{env:HOME}` or `~`
here, and does not use v1's `tui.json(c)` plugin list. Keep unrelated UI preferences.

OpenCode saves preferences by replacing `cli.json`. If you manage configuration
declaratively, seed it once or manage a writable copy rather than assume an
immutable symlink remains in place. Updating a seed alone does not update an
already-created live file.

Populate Neovim's `OPENCODE_PASSWORD` before setup. The legacy
`OPENCODE_SERVER_PASSWORD` is accepted when the new variable is absent. V2 uses
Basic username `opencode`; `OPENCODE_SERVER_USERNAME` is no longer a username
configuration option. Both Lua requests and the child TUI use the same resolved
password. Provider credentials belong with the backend, not in the TUI wrapper.

## Review delivery

The direct API sends native `text`, `files = [{uri, name}]`, and `delivery`.
Ranged URIs retain one-based inclusive `?start=N&end=M` selections. The server
materializes those attachments in the session's location and selects the
session's current agent/model/variant. The plugin no longer reads old user
messages to infer a model.

`review.delivery = "queue"` is the default: feedback waits for the next run if
the session is busy. `"steer"` makes it available to the running agent. This is
separate from collecting comments in Neovim's local review queue; the local queue
still sends only when explicitly requested.

A valid native inbox acknowledgement confirms durable admission, not completed
execution. Only acknowledged, unchanged queued comments are removed. Failed or
uncertain requests keep their comments and are never resubmitted automatically.
After a timeout or malformed acknowledgement, inspect the TUI before manually
sending again. The local review queue is still lost when Neovim exits.

## Update notification hooks

Native events retain their `type`, `data`, and optional `location`. There is no
v1 `properties` adapter and no synthesized v1 lifecycle event stream.

| V1 integration | V2 integration |
| --- | --- |
| `session.status` / `session.idle` | `session.execution.started` / `.succeeded`, with `.failed` and `.interrupted` handled separately |
| `session.error` | `session.execution.failed`, error under `event.data.error` |
| `question.asked` / `.replied` | `form.created` / `.replied` / `.cancelled` |
| `permission.asked` / `.replied` | Same names, payload under `event.data` |
| `message.updated` | Native typed message/inbox events; no blanket alias |
| `GET /session/:id` returning the object | `GET /api/session/:id` returning `{data: Session.Info}` |

`OpencodeActiveEvent:*` is filtered to the session visible in this embedded TUI.
Most events own `data.sessionID`; `form.created` owns `data.form.sessionID`.
Child-session events and global forms are not relabeled as active-session events.
Use `require("opencode.client").get_session(id, callback)` for native session
metadata; it unwraps `data` and handles authentication. Custom notification hooks
remain responsible for their own caching and deduplication.

`OpencodeEvent:*` receives server control events, the active session's events,
and events explicitly scoped to the same directory/workspace. Connection health
is independent of filtering. Switching sessions does not replace the global
stream.

The SSE feed is volatile. The parser handles fragmented frames, CRLF, multiline
data, and comment heartbeats. Its watchdog allows 45 seconds for a server that
normally sends a heartbeat every 15 seconds. On reconnect, `OpencodeResync`
triggers disk checks and `OpencodeSessionRefreshed` supplies the current session
snapshot. Missed lifecycle events are not replayed as new notifications.

## Reload behavior

V2 does not consistently publish file edits yet. The plugin handles
`filesystem.changed` and coalesces disk checks after tool/shell/execution
settlement, reverts, reconnects, and returning to the editor. Set
`vim.o.autoread = true`. Only loaded unmodified buffers are eligible; dirty buffers
keep their unsaved text. Without a concrete filename, checks are limited to the
active location's directory. There is no remote-to-local filesystem mapping.

## Migration checklist

Install OpenCode v2 and start or select a compatible backend before updating the
plugin. Neovim selects the server explicitly and supplies its password; ordinary
terminal use of `opencode` can retain upstream behavior.

1. Update the installed plugin to a v2-compatible commit. Keep your server URL,
   mappings, terminal layout, `autoread`, and `OPENTUI_GRAPHICS=0` settings.
2. Register the installed plugin's absolute directory in writable `cli.json`,
   keep `prompt.editor = true`, and restart the embedded TUI. If you generate
   the configuration from a template, update both the template and live file.
3. Provide the backend password in Neovim's environment before plugin setup.
4. Update custom notification hooks for native lifecycle/form events and
   `event.data` fields. Use the plugin's `get_session` helper for session
   metadata, and recheck notification deduplication.
5. Check any other OpenCode plugins for v2 compatibility before enabling them.

## Validation

The deterministic suite runs with `nix develop --command bun run test` after
`bun install --frozen-lockfile`. It covers native request/acknowledgement shapes,
credential precedence and transport, URI ranges, queue failure/concurrency,
stream framing, workspace scope, heartbeat/retry cleanup, route-switch races,
loading without installed packages, and safe buffer reload with inherited or
explicit `autoread` settings.
Typechecking uses the real published SDK, not local ambient declarations.

For a real-server check, use an isolated Neovim configuration and a writable CLI
config copy containing this checkout's bridge. Use a disposable project the
server is allowed to write to and sessions created only for the test:

- Launch new/continue/explicit-session modes in Snacks split and tab layouts.
- Confirm `:Opencode status` reports the expected session, location, and connected
  editor WebSocket; send a native visual-range mention and a normal prompt.
- Submit a direct review and a multi-comment queue. Inspect persisted native
  user messages for ranged attachments and verify the selected agent/model.
- Remain idle beyond 15 seconds, reconnect after a missed disk change, and check
  clean-buffer reload while a dirty buffer retains its unsaved text.
- Exercise permission/form attention and session switching without forwarding
  unrelated or child-session events. Close the TUI and confirm server lifetime
  is unchanged. Delete only the test sessions/files afterward.

Live checks passed with OpenCode 2.0.1, Neovim 0.12.4, Snacks terminal, and a
server running in the Fence sandbox: new/continue/explicit-session launch,
split and tab layouts, native ranged mentions, prompt submission, direct and batched reviews,
idle heartbeat, clean-buffer reload, dirty-buffer preservation, and reconnect
after a missed disk edit. The bridge also loaded without `node_modules`. The
deterministic Lua suite passed on Neovim 0.11.5 and 0.12.4. Permission/form UI
flows and remote workspace runtimes have fixture/source coverage only.

## Source references

These implementation contracts were checked in the pinned upstream source:

- [CLI launch and explicit server connection](https://github.com/anomalyco/opencode/blob/41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3/packages/cli/src/commands/commands.ts)
- [Native TUI context](https://github.com/anomalyco/opencode/blob/41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3/packages/plugin/src/tui/context.ts)
- [Native session HTTP contracts](https://github.com/anomalyco/opencode/blob/41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3/packages/protocol/src/groups/session.ts)
- [Attachment input](https://github.com/anomalyco/opencode/blob/41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3/packages/schema/src/prompt-input.ts)
- [SSE handler and heartbeat](https://github.com/anomalyco/opencode/blob/41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3/packages/server/src/handlers/event.ts)
- [Native session events](https://github.com/anomalyco/opencode/blob/41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3/packages/schema/src/session-event.ts)
