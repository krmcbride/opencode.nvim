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

let lastPayload = "";
let notifiedError = false;

const forwardedEventTypes = [
  "session.status",
  "session.idle",
  "session.error",
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
