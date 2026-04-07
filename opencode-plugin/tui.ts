import type { TuiPlugin, TuiPluginApi, TuiPluginModule } from "@opencode-ai/plugin/tui"

const id = "krmcbride/opencode-nvim-bridge"

const bridgeUrl = process.env.OPENCODE_NVIM_BRIDGE_URL
const bridgeToken = process.env.OPENCODE_NVIM_BRIDGE_TOKEN
const instanceID = process.env.OPENCODE_NVIM_INSTANCE_ID

let lastPayload = ""
let notifiedInit = false
let notifiedSuccess = false
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
  if (!canBridge()) {
    if (!notifiedError) {
      notifiedError = true
      toast(api, "missing bridge env", "warning")
    }
    return
  }

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

    if (!notifiedSuccess) {
      notifiedSuccess = true
      toast(api, `publish ok: ${route}`, "success")
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
  if (!notifiedInit) {
    notifiedInit = true
    toast(api, canBridge() ? "loaded with env" : "loaded without env")
  }

  syncRoute(api)

  const timer = setInterval(() => {
    syncRoute(api)
  }, 300)

  api.command.register(() => [
    {
      title: "NVim Bridge Debug",
      value: "nvim.bridge.debug",
      category: "Plugin",
      onSelect() {
        const current = api.route.current
        toast(api, current.name === "session" ? `route=session ${current.params.sessionID}` : `route=${current.name}`)
      },
    },
  ])

  api.lifecycle.onDispose(() => {
    clearInterval(timer)
  })
}

const plugin: TuiPluginModule & { id: string } = {
  id,
  tui,
}

export default plugin
