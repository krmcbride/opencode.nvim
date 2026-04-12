---Embedded OpenCode conversation-session state shared across the plugin.
---
---Here, "session" means an OpenCode TUI conversation/session (the thing with a
---session id inside the attached TUI), not an HTTP session or transport-layer
---connection.
---
---This state does not live in `opencode.bridge` because the bridge is only the
---transport that receives updates from the child TUI process. The session state
---itself is consumed more broadly:
---1. `opencode.bridge` publishes active route/session/cwd into it
---2. `opencode.terminal` reads the target session id for attach-mode behavior
---3. `opencode.client` reads cwd for backend SSE scoping
---4. `opencode.review` / `opencode.lua` read the active OpenCode session id for
---   direct session-targeted actions
---
---Keeping this as a separate shared-state module avoids coupling those consumers
---to the bridge transport details.
---
---This module owns two related concepts:
---1. the active TUI route / OpenCode session id / cwd reported by the local bridge
---2. the OpenCode session id the embedded terminal should target after an explicit attach
---
---`OpencodeSessionChanged` is emitted only for changes to the active bridge
---reported TUI session state. Explicit target/follow mutations are local coordination state
---and do not emit that event.
local M = {}

---@alias opencode.SessionRoute "home"|"session"

---@class opencode.ActiveSessionUpdate
---@field route? opencode.SessionRoute
---@field session_id? string|nil OpenCode session id reported by the embedded TUI
---@field cwd? string|nil Current working directory reported by the embedded TUI
---@field instance_id? string|nil Bridge instance id for the publishing TUI process

---@class opencode.SessionState
---@field route opencode.SessionRoute
---@field session_id string|nil Active OpenCode session id currently visible in the embedded TUI
---@field target_session_id string|nil OpenCode session id the local terminal should attach/follow
---@field instance_id string|nil Bridge instance id for the active embedded TUI process
---@field cwd string|nil Current working directory reported by the embedded TUI
---@field follow_active_session boolean Whether explicit attach mode should follow the active embedded TUI session id

---@type opencode.SessionState
local state = {
  route = "home",
  session_id = nil,
  target_session_id = nil,
  instance_id = nil,
  cwd = nil,
  follow_active_session = false,
}

---Emit `OpencodeSessionChanged` for active embedded-TUI session changes.
local function emit_changed()
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "OpencodeSessionChanged",
      data = {
        route = state.route,
        session_id = state.session_id,
        instance_id = state.instance_id,
        cwd = state.cwd,
      },
    })
  end)
end

---Update the active embedded-TUI route/session/cwd reported by the bridge.
---
---When `follow_active_session` is enabled, an active OpenCode session id also
---becomes the terminal target session id used by `opencode.terminal`.
---@param payload opencode.ActiveSessionUpdate
function M.update_active(payload)
  local next_route = payload.route == "session" and "session" or "home"
  local next_session_id = next_route == "session" and payload.session_id or nil
  local next_cwd = payload.cwd or state.cwd
  local next_instance_id = payload.instance_id or state.instance_id
  local changed = state.route ~= next_route
    or state.session_id ~= next_session_id
    or state.cwd ~= next_cwd
    or state.instance_id ~= next_instance_id

  state.route = next_route
  state.session_id = next_session_id
  state.cwd = next_cwd
  state.instance_id = next_instance_id

  if state.follow_active_session and next_session_id and next_session_id ~= "" then
    state.target_session_id = next_session_id
  end

  if not changed then
    return
  end

  emit_changed()
end

---Set the explicit OpenCode session id the embedded terminal should target.
---
---This is local coordination state used for attach-mode behavior and does not
---emit `OpencodeSessionChanged`.
---@param session_id string|nil
function M.set_target_session_id(session_id)
  state.target_session_id = session_id and session_id ~= "" and session_id or nil
end

---Control whether explicit attach mode should follow the active TUI session id.
---@param value boolean
function M.set_follow_active_session(value)
  state.follow_active_session = value == true
end

---Return the explicit terminal attach target, if any.
---@return string|nil
function M.get_target_session_id()
  return state.target_session_id
end

---Return the current embedded-TUI session state plus local terminal target state.
---@return opencode.SessionState
function M.get_state()
  return {
    route = state.route,
    session_id = state.session_id,
    target_session_id = state.target_session_id,
    instance_id = state.instance_id,
    cwd = state.cwd,
    follow_active_session = state.follow_active_session,
  }
end

return M
