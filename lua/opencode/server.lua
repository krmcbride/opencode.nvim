---Server discovery for opencode.
---
---Finds running opencode processes and matches them to this Neovim instance.
---
---Discovery Flow:
---  1. get_processes() - Find all `opencode --port` PIDs via pgrep, get their
---     listening ports via lsof
---  2. find_servers() - Validate each process by calling its /path HTTP endpoint
---     to get the working directory
---  3. find_server_inside_nvim_cwd() - Filter to servers whose cwd is within
---     Neovim's cwd, prefer ones spawned by this Neovim (child process)
---
---Entry Point:
---  get_port(callback, launch) - Returns port of matching server, optionally
---  launching opencode if none found. Polls with retries after launch.
local M = {}

---@class opencode.Server
---@field pid number
---@field port number
---@field cwd string

---Find all running opencode processes and their listening ports.
---
---Uses pgrep to find PIDs matching "opencode.*--port", then lsof to find
---which TCP port each PID is listening on.
---
---@return { pid: number, port: number }[]
local function get_processes()
  -- Find all PIDs running "opencode --port ..."
  local pgrep = vim.system({ "pgrep", "-f", "opencode.*--port" }, { text = true }):wait()
  require("opencode.util").check_system_call(pgrep, "pgrep")

  local processes = {}
  for pgrep_line in pgrep.stdout:gmatch("[^\r\n]+") do
    local pid = tonumber(pgrep_line)
    if pid then
      -- Find listening TCP port for this PID
      -- lsof flags: -w (no warnings), -iTCP (TCP only), -sTCP:LISTEN (listening only),
      -- -P (numeric ports), -n (no DNS), -a (AND conditions), -p (specific PID)
      local lsof = vim
          .system({ "lsof", "-w", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-a", "-p", tostring(pid) }, { text = true })
          :wait()
      require("opencode.util").check_system_call(lsof, "lsof")
      -- Parse lsof output: columns are COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
      -- NAME column (9th) contains "host:port" like "*:8080" or "127.0.0.1:3000"
      for line in lsof.stdout:gmatch("[^\r\n]+") do
        local parts = vim.split(line, "%s+")
        if parts[1] ~= "COMMAND" then
          local port_str = parts[9] and parts[9]:match(":(%d+)$")
          if port_str then
            local port = tonumber(port_str)
            if port then
              table.insert(processes, { pid = pid, port = port })
            end
          end
        end
      end
    end
  end
  return processes
end

---Validate processes by querying their HTTP endpoints.
---
---For each process found by get_processes(), calls GET /path to verify it's
---a real opencode server and to get its working directory.
---
---@return opencode.Server[]
local function find_servers()
  local processes = get_processes()
  if #processes == 0 then
    error("No `opencode` processes found", 0)
  end

  local servers = {}
  for _, process in ipairs(processes) do
    -- Query the /path endpoint to validate server and get its cwd
    local ok, path = pcall(require("opencode.client").get_path, process.port)
    if ok then
      table.insert(servers, {
        pid = process.pid,
        port = process.port,
        cwd = path.directory or path.worktree,
      })
    end
  end
  if #servers == 0 then
    error("No valid `opencode` servers found", 0)
  end
  return servers
end

---Check if a process was spawned by this Neovim instance.
---
---Walks up the process tree (child -> parent -> grandparent -> ...) to see if
---Neovim's PID appears as an ancestor. Used to prefer "our" opencode server
---when multiple servers match the cwd.
---
---@param pid number Process ID to check
---@return boolean True if pid is a descendant of this Neovim process
local function is_descendant_of_neovim(pid)
  local neovim_pid = vim.fn.getpid()
  local current_pid = pid
  -- Walk up to 10 levels (plenty for nvim -> shell -> opencode)
  for _ = 1, 10 do
    local ps = vim.system({ "ps", "-o", "ppid=", "-p", tostring(current_pid) }, { text = true }):wait()
    require("opencode.util").check_system_call(ps, "ps")
    local parent_pid = tonumber(ps.stdout)
    if not parent_pid or parent_pid == 1 then
      return false -- Reached init/root, not a descendant
    elseif parent_pid == neovim_pid then
      return true  -- Found Neovim in ancestry
    end
    current_pid = parent_pid
  end
  return false -- Gave up after 10 levels
end

---Find the best matching server for this Neovim instance.
---
---Filters servers to those whose cwd starts with Neovim's cwd (allowing for
---subdirectory matches like worktrees). If multiple match, prefers the one
---spawned by this Neovim process.
---
---@return opencode.Server
local function find_server_inside_nvim_cwd()
  local found_server
  local nvim_cwd = vim.fn.getcwd()
  for _, server in ipairs(find_servers()) do
    -- Check if server's cwd is inside Neovim's cwd (prefix match)
    if server.cwd:find(nvim_cwd, 1, true) == 1 then
      found_server = server
      -- Prefer server spawned by this Neovim instance (stop searching)
      if is_descendant_of_neovim(server.pid) then
        break
      end
      -- Otherwise keep searching in case a better match exists
    end
  end
  if not found_server then
    error("No `opencode` servers inside Neovim's CWD", 0)
  end
  return found_server
end

---Poll for a server port with retries.
---
---Used after launching opencode to wait for it to start accepting connections.
---Tries every 500ms for up to 3 seconds (6 attempts total).
---
---@param fn fun(): number Function that returns port or throws error
---@param callback fun(err: string|nil, port: number|nil)
local function poll_for_port(fn, callback)
  local retries = 0
  local timer = vim.uv.new_timer()
  if not timer then
    callback("Failed to create timer for polling `opencode` port", nil)
    return
  end
  local timer_closed = false
  timer:start(
    500, -- Initial delay before first attempt
    500, -- Interval between retries
    vim.schedule_wrap(function()
      if timer_closed then
        return
      end
      local ok, result = pcall(fn)
      if ok or retries >= 5 then
        -- Success or exhausted retries
        timer_closed = true
        timer:stop()
        timer:close()
        if ok then
          callback(nil, result)
        else
          callback(tostring(result), nil)
        end
      else
        retries = retries + 1
      end
    end)
  )
end

---Get the opencode server's port (main entry point).
---
---If a port is configured, validates that server is responding.
---Otherwise, discovers a server matching Neovim's cwd.
---If no server found and launch=true, starts opencode and polls for it.
---
---@param callback fun(err: string|nil, port: number|nil)
---@param launch? boolean Whether to launch opencode if not found (default: true)
function M.get_port(callback, launch)
  launch = launch ~= false

  local configured_port = require("opencode.config").opts.port
  local find_port_fn = function()
    if configured_port then
      -- Use configured port, just validate it's responding
      local ok, path = pcall(require("opencode.client").get_path, configured_port)
      if ok and path then
        return configured_port
      else
        error("No `opencode` responding on configured port: " .. configured_port, 0)
      end
    else
      -- Auto-discover server matching Neovim's cwd
      return find_server_inside_nvim_cwd().port
    end
  end

  -- Try to find server immediately
  local initial_ok, initial_result = pcall(find_port_fn)
  if initial_ok then
    callback(nil, initial_result)
    return
  end

  -- No server found - optionally launch one
  if launch then
    vim.notify(initial_result .. " — starting `opencode`…", vim.log.levels.INFO, { title = "opencode" })
    local start_ok, start_result = pcall(require("opencode.terminal").start)
    if not start_ok then
      callback("Error starting `opencode`: " .. start_result, nil)
      return
    end
  end

  -- Poll for server to become available (either just launched, or waiting for external start)
  poll_for_port(find_port_fn, callback)
end

return M
