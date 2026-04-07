import type { TuiPlugin, TuiPluginApi, TuiPluginModule } from "@opencode-ai/plugin/tui"

const id = "krmcbride/opencode-nvim-bridge"

const bridgeUrl = process.env.OPENCODE_NVIM_BRIDGE_URL
const bridgeToken = process.env.OPENCODE_NVIM_BRIDGE_TOKEN
const instanceID = process.env.OPENCODE_NVIM_INSTANCE_ID

let lastPayload = ""
let notifiedError = false

function canBridge() {
  return Boolean(bridgeUrl && bridgeToken && instanceID)
}

function toast(api: TuiPluginApi, message: string, variant: "info" | "success" | "warning" | "error" = "info") {
  api.ui.toast({
    title: "nvim bridge",
    message,
    variant,
    duration: 2500,
  })
}

async function publish(api: TuiPluginApi, route: "home" | "session", sessionID?: string) {
  if (!canBridge()) return

  const payload = {
    token: bridgeToken,
    instanceID,
    route,
    sessionID: route === "session" ? sessionID ?? null : null,
    cwd: process.cwd(),
  }
  const body = JSON.stringify(payload)
  if (body === lastPayload) return
  lastPayload = body

  try {
    const response = await fetch(bridgeUrl!, {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body,
    })

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`)
    }
  } catch (error) {
    if (!notifiedError) {
      notifiedError = true
      const message = error instanceof Error ? error.message : String(error)
      toast(api, `publish failed: ${message}`, "error")
    }
  }
}

function syncRoute(api: TuiPluginApi) {
  const current = api.route.current
  if (current.name === "session") {
    void publish(api, "session", current.params.sessionID)
    return
  }

  void publish(api, "home")
}

const tui: TuiPlugin = async (api) => {
  syncRoute(api)

  const timer = setInterval(() => {
    syncRoute(api)
  }, 300)

  api.lifecycle.onDispose(() => {
    clearInterval(timer)
  })
}

const plugin: TuiPluginModule & { id: string } = {
  id,
  tui,
}

export default plugin
