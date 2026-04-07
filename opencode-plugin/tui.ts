import type {
  TuiPlugin,
  TuiPluginApi,
  TuiPluginModule,
} from "@opencode-ai/plugin/tui";

const id = "opencode-nvim-bridge";

const bridgeUrl = process.env.OPENCODE_NVIM_BRIDGE_URL;
const bridgeToken = process.env.OPENCODE_NVIM_BRIDGE_TOKEN;
const instanceID = process.env.OPENCODE_NVIM_INSTANCE_ID;

let lastPayload = "";
let notifiedError = false;

const forwardedEventTypes = [
  "session.status",
  "session.idle",
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

function currentState(api: TuiPluginApi) {
  const current = api.route.current;
  return {
    route:
      current.name === "session" ? ("session" as const) : ("home" as const),
    sessionID: current.name === "session" ? current.params.sessionID : null,
    cwd: process.cwd(),
  };
}

async function publishEvent(api: TuiPluginApi, event: { type: string }) {
  if (!canBridge()) return;

  const payload = {
    kind: "event",
    token: bridgeToken,
    instanceID,
    ...currentState(api),
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

  const unsubscribers = forwardedEventTypes.map((type) =>
    api.event.on(type, (event) => {
      void publishEvent(api, event);
    }),
  );

  const timer = setInterval(() => {
    syncRoute(api);
  }, 300);

  api.lifecycle.onDispose(() => {
    clearInterval(timer);
    for (const unsubscribe of unsubscribers) {
      unsubscribe();
    }
  });
};

const plugin: TuiPluginModule & { id: string } = {
  id,
  tui,
};

export default plugin;
