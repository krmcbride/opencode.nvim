/**
 * OpenCode TUI plugin that bridges embedded `opencode attach` state back to
 * the current Neovim instance.
 *
 * This is not a regular server-side OpenCode plugin.
 *
 * It runs inside the child TUI process created by `opencode.nvim` when the
 * plugin embeds `opencode attach` in a Snacks terminal. From that process, the
 * TUI can see its own active route, session, cwd, and local UI events, but it
 * cannot call Neovim Lua directly.
 *
 * This plugin exists to close that gap. It reads loopback bridge connection
 * details from environment variables injected by Neovim, then POSTs small JSON
 * payloads back to the local bridge server in `lua/opencode/bridge.lua`.
 * Neovim uses those payloads to track:
 *
 * 1. which TUI route is currently visible (`home` vs `session`)
 * 2. which OpenCode session/conversation the embedded TUI is showing
 * 3. which cwd the child TUI process is using
 * 4. a small set of TUI-local events that do not naturally flow through the
 *    backend HTTP/SSE client
 *
 * High-level flow:
 *
 *   Neovim Lua                      child `opencode attach` process
 *   (`opencode.nvim`)               + this TUI plugin module
 *        ^                                      |
 *        |    localhost HTTP POST               |
 *        +--------------------------------------+
 *
 * This is intentionally narrow in scope: it mirrors local embedded-TUI state
 * into Neovim. It is not trying to be a second backend API client.
 */
import type {
  TuiPlugin,
  TuiPluginApi,
  TuiPluginModule,
} from "@opencode-ai/plugin/tui";

const id = "opencode-nvim-bridge";

// Keep these bridge protocol constants aligned with `lua/opencode/constants.lua`.
const BRIDGE_ENV = {
  URL: "OPENCODE_NVIM_BRIDGE_URL",
  TOKEN: "OPENCODE_NVIM_BRIDGE_TOKEN",
  INSTANCE_ID: "OPENCODE_NVIM_INSTANCE_ID",
} as const;

const bridgeUrl = process.env[BRIDGE_ENV.URL];
const bridgeToken = process.env[BRIDGE_ENV.TOKEN];
const instanceID = process.env[BRIDGE_ENV.INSTANCE_ID];

// Route polling runs on a short interval, so skip bridge writes when the
// visible TUI state is unchanged.
let lastPayload = "";
let notifiedError = false;

// Only forward local TUI events that Neovim is likely to care about. Backend
// session updates still come from the normal HTTP/SSE client on the Lua side.
const forwardedEventTypes = [
  "session.status",
  "session.idle",
  "session.error",
  "message.updated",
  "permission.asked",
  "permission.replied",
  "question.asked",
  "question.replied",
] as const;

function canBridge() {
  return Boolean(bridgeUrl && bridgeToken && instanceID);
}

function toast(
  api: TuiPluginApi,
  message: string,
  variant: "info" | "success" | "warning" | "error" = "info",
) {
  api.ui.toast({
    title: "nvim bridge",
    message,
    variant,
    duration: 2500,
  });
}

async function publish(
  api: TuiPluginApi,
  route: "home" | "session",
  sessionID?: string,
) {
  if (!canBridge()) return;

  const payload = {
    token: bridgeToken,
    instanceID,
    route,
    sessionID: route === "session" ? (sessionID ?? null) : null,
    cwd: process.cwd(),
  };
  const body = JSON.stringify(payload);
  if (body === lastPayload) return;

  try {
    const response = await fetch(bridgeUrl!, {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body,
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    lastPayload = body;
    notifiedError = false;
  } catch (error) {
    if (!notifiedError) {
      notifiedError = true;
      const message = error instanceof Error ? error.message : String(error);
      toast(api, `publish failed: ${message}`, "error");
    }
  }
}

// Reduce the richer TUI router state down to the small bridge payload shape the
// Neovim side needs for attach-mode coordination.
function currentState(api: TuiPluginApi) {
  const current = api.route.current;
  return {
    route:
      current.name === "session" ? ("session" as const) : ("home" as const),
    sessionID: current.name === "session" ? current.params.sessionID : null,
    cwd: process.cwd(),
  };
}

function eventSessionID(event: { properties?: { sessionID?: unknown } }) {
  return typeof event.properties?.sessionID === "string"
    ? event.properties.sessionID
    : null;
}

async function publishEvent(
  api: TuiPluginApi,
  event: { type: string; properties?: { sessionID?: unknown } },
) {
  if (!canBridge()) return;

  const current = currentState(api);
  const payload = {
    kind: "event",
    token: bridgeToken,
    instanceID,
    ...current,
    // Prefer the event's explicit session when present. That keeps Neovim's
    // local event handling correctly scoped even if the visible route changed
    // around the same time.
    sessionID: eventSessionID(event) ?? current.sessionID,
    event,
  };

  try {
    const response = await fetch(bridgeUrl!, {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    notifiedError = false;
  } catch (error) {
    if (!notifiedError) {
      notifiedError = true;
      const message = error instanceof Error ? error.message : String(error);
      toast(api, `event publish failed: ${message}`, "error");
    }
  }
}

function syncRoute(api: TuiPluginApi) {
  const current = api.route.current;
  if (current.name === "session") {
    void publish(api, "session", current.params.sessionID);
    return;
  }

  void publish(api, "home");
}

const tui: TuiPlugin = async (api) => {
  syncRoute(api);

  const disposers = forwardedEventTypes.map((type) =>
    api.event.on(type, (event) => {
      void publishEvent(api, event);
    }),
  );

  // A lightweight polling loop is the simplest reliable way to notice route or
  // session switches inside the TUI. `publish()` dedupes unchanged snapshots,
  // so steady-state polling stays quiet.
  const timer = setInterval(() => {
    syncRoute(api);
  }, 300);

  api.lifecycle.onDispose(() => {
    clearInterval(timer);
    for (const dispose of disposers) {
      dispose();
    }
  });
};

const plugin: TuiPluginModule & { id: string } = {
  id,
  tui,
};

export default plugin;
