import type { OpenCodeEvent } from "@opencode/client";
import type { Plugin } from "@opencode/plugin/tui";

type Context = {
  ui: Pick<Plugin.Context["ui"], "router" | "toast">;
  data: {
    session: Pick<Plugin.Context["data"]["session"], "get">;
    location: Pick<Plugin.Context["data"]["location"], "default">;
  };
};

const forwarded = new Set<OpenCodeEvent["type"]>([
  "session.execution.started",
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
  "session.retry.scheduled",
  "session.inbox.enqueued",
  "session.inbox.delivered",
  "session.inbox.cancelled",
  "session.agent.selected",
  "session.model.selected",
  "permission.asked",
  "permission.replied",
  "form.created",
  "form.replied",
  "form.cancelled",
]);

export function currentState(context: Context) {
  const route = context.ui.router.current();
  const session = route.type === "session" ? context.data.session.get(route.sessionID) : undefined;
  const location = session?.location ?? context.data.location.default();
  return {
    // Wait for the session cache before exposing a target for direct reviews.
    route: session ? "session" : "home",
    sessionID: session?.id ?? null,
    cwd: location.directory,
    workspaceID: location.workspaceID ?? null,
  };
}

export function eventSessionID(event: OpenCodeEvent): string | undefined {
  if (event.type === "form.created") return event.data.form.sessionID;
  if ("sessionID" in event.data && typeof event.data.sessionID === "string") return event.data.sessionID;
}

// Each setup owns its transport state. Hot reloads cannot inherit an old
// deduplication snapshot or keep publishing after their cleanup runs.
export function createBridge(
  context: Context,
  env: Record<string, string | undefined>,
  transport: typeof fetch = fetch,
) {
  const url = env.OPENCODE_NVIM_BRIDGE_URL;
  const token = env.OPENCODE_NVIM_BRIDGE_TOKEN;
  const instanceID = env.OPENCODE_NVIM_INSTANCE_ID;
  if (!url || !token || !instanceID) return;

  let disposed = false;
  let lastState = "";
  let syncing = false;
  let notifiedError = false;
  let pending = Promise.resolve();
  const controllers = new Set<AbortController>();

  async function post(payload: object) {
    if (disposed) return false;
    const controller = new AbortController();
    controllers.add(controller);
    const timeout = setTimeout(() => controller.abort(), 2000);
    try {
      const response = await transport(url!, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token, instanceID, ...payload }),
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      notifiedError = false;
      return true;
    } catch {
      if (!disposed && !notifiedError) {
        notifiedError = true;
        context.ui.toast.show({
          title: "nvim bridge",
          message: "Could not reach Neovim; bridge updates will retry.",
          variant: "error",
          duration: 2500,
        });
      }
      return false;
    } finally {
      clearTimeout(timeout);
      controllers.delete(controller);
    }
  }

  async function publishState(state = currentState(context)) {
    const body = JSON.stringify(state);
    if (body === lastState) return true;
    if (!(await post(state))) return false;
    lastState = body;
    return true;
  }

  return {
    sync() {
      if (disposed || syncing) return pending;
      syncing = true;
      pending = pending.then(async () => {
        try {
          if (!disposed) await publishState();
        } finally {
          syncing = false;
        }
      });
      return pending;
    },
    event(event: OpenCodeEvent) {
      if (disposed || !forwarded.has(event.type)) return;
      const state = currentState(context);
      if (state.route !== "session" || eventSessionID(event) !== state.sessionID) return;
      pending = pending.then(async () => {
        if (disposed || !(await publishState(state))) return;
        await post({ kind: "event", ...state, event });
      });
    },
    dispose() {
      disposed = true;
      for (const controller of controllers) controller.abort();
    },
  };
}
