require("i3ipc.pkgpath")
local struct = require("struct")
local uv = require("luv")
local json = require("cjson")
local Reader = require("i3ipc.reader")
local wrap_node = require("i3ipc.node-mt")
local Cmd = require("i3ipc.cmd")

local Connection = {}
Connection.__index = Connection

local MAGIC = "i3-ipc"
local HEADER_SIZE = #MAGIC + 8

-- luacheck: push no max line length
local COMMAND = {
  RUN_COMMAND       = 0,  -- Run the payload as an i3 command (like the commands you can bind to keys).
  GET_WORKSPACES    = 1,  -- Get the list of current workspaces.
  SUBSCRIBE         = 2,  -- Subscribe this IPC connection to the event types specified in the message payload. See [events].
  GET_OUTPUTS       = 3,  -- Get the list of current outputs.
  GET_TREE          = 4,  -- Get the i3 layout tree.
  GET_MARKS         = 5,  -- Gets the names of all currently set marks.
  GET_BAR_CONFIG    = 6,  -- Gets the specified bar configuration or the names of all bar configurations if payload is empty.
  GET_VERSION       = 7,  -- Gets the i3 version.
  GET_BINDING_MODES = 8,  -- Gets the names of all currently configured binding modes.
  GET_CONFIG        = 9,  -- Returns the last loaded i3 config.
  SEND_TICK         = 10, -- Sends a tick event with the specified payload.
  SYNC              = 11, -- Sends an i3 sync event with the specified random value to the specified window.
  GET_BINDING_STATE = 12, -- Request the current binding state, i.e. the currently active binding mode name.
  -- Sway-only
  GET_INPUTS        = 100,
  GET_SEATS         = 101,
}

local EVENT = {
  WORKSPACE        = {0, "workspace"}, -- Sent when the user switches to a different workspace, when a new workspace is initialized or when a workspace is removed (because the last client vanished).
  OUTPUT           = {1, "output"}, -- Sent when RandR issues a change notification (of either screens, outputs, CRTCs or output properties).
  MODE             = {2, "mode"}, -- Sent whenever i3 changes its binding mode.
  WINDOW           = {3, "window"}, -- Sent when a client’s window is successfully reparented (that is when i3 has finished fitting it into a container), when a window received input focus or when certain properties of the window have changed.
  BARCONFIG_UPDATE = {4, "barconfig_update"}, -- Sent when the hidden_state or mode field in the barconfig of any bar instance was updated and when the config is reloaded.
  BINDING          = {5, "binding"}, -- Sent when a configured command binding is triggered with the keyboard or mouse
  SHUTDOWN         = {6, "shutdown"}, -- Sent when the ipc shuts down because of a restart or exit by user command
  TICK             = {7, "tick"},
  BAR_STATE_UPDATE = {20, "bar_state_update"},
  INPUT            = {21, "input"},
}
-- luacheck: pop

local function is_builtin_event(e)
  if type(e) ~= "table" or #e ~= 2 then return false end
  for _, v in pairs(EVENT) do
    if v[1] == e[1] and v[2] == e[2] then return true end
  end
  return false
end

local function parse_header(raw)
  local magic, len, type = struct.unpack("< c6 i4 i4", raw)
  if magic ~= MAGIC then return false end
  return true, len, type
end

local function serialize(type, payload)
  payload = payload or ""
  return struct.pack("< c6 i4 i4", MAGIC, #payload, type)..payload
end

function Connection._get_sockpath()
  local sockpath = os.getenv("SWAYSOCK") or os.getenv("I3SOCK")
  if sockpath == nil then
    error("Neither of SWAYSOCK nor I3SOCK environment variables are set")
  end
  return sockpath
end

function Connection:new(opts)
  opts = opts or {}
  local pipe = uv.new_pipe(true)

  local ipc_reader = Reader:new(function(data)
    if #data < HEADER_SIZE then
      return nil
    end
    local --[[parsed]]_, msg_len, msg_type = parse_header(data:sub(1, HEADER_SIZE))
    local raw_payload = data:sub(HEADER_SIZE + 1, HEADER_SIZE + msg_len)
    if #raw_payload < msg_len then
      return nil
    end
    local ok, payload = pcall(json.decode, raw_payload)
    if not ok then
      return nil
    end
    local message = { type = msg_type, payload = payload }
    return message, data:sub(HEADER_SIZE + msg_len + 1)
  end)

  local conn = setmetatable({
    ipc_reader = ipc_reader,
    cmd_result_reader = Reader:new(),
    pipe = pipe,
    handlers = {},
    subscribed_to = {},
    main_finished = false,
  }, self)

  if opts.cmd == true then
    conn.cmd = Cmd:new()
  end
  coroutine.wrap(function()
    while true do
      local msg = conn.ipc_reader:recv()
      if bit.band(bit.rshift(msg.type, 31), 1) == 1 then
        local event_id = bit.band(msg.type, 0x7f)
        local handlers = conn.handlers[event_id] or {}
        for _, handler in pairs(handlers) do
          if msg.payload.change == handler.change then
            coroutine.wrap(function()
              handler.callback(conn, msg.payload)
            end)()
          end
        end
      else
        conn.cmd_result_reader:push(msg.payload)
      end
    end
  end)()

  return conn
end

function Connection:connect_socket(sockpath)
  sockpath = sockpath or self:_get_sockpath()
  local co = coroutine.running()
  self.pipe:connect(sockpath, function()
    assert(coroutine.resume(co))
  end)
  coroutine.yield()
  self.pipe:read_start(function(err, chunk)
    if err ~= nil or chunk == nil then
      return
    end
    self.ipc_reader:push(chunk)
  end)
  if self.cmd then
    self.cmd:listen_socket()
  end
end

function Connection:send(type, payload)
  local event_id = type
  local msg = serialize(event_id, payload)
  self.pipe:write(msg)
  return self.cmd_result_reader:recv()
end

local function resolve_event(event)
  if is_builtin_event(event) then
    -- i.e. EVENT.WINDOW
    return {{ id = event[1], name = event[2] }}
  elseif type(event) == "string" then
    -- i.e. "window::new" or just "window"
    local name, change = event:match("(%w+)::(%w+)")
    if name == nil then name = event end
    for _, v in pairs(EVENT) do
      if v[2] == name then
        return {{ id = v[1], name = v[2], change = change }}
      end
    end
  elseif type(event) == "table" then
    -- i.e. { EVENT.WINDOW, "workspace::focus" }
    local result = {}
    for _, v in ipairs(event) do
      local resolved = resolve_event(v)
      for _, r in ipairs(resolved) do
        table.insert(result, r)
      end
    end
    return result
  else
    error("Invalid event type")
  end
end

function Connection:on(event, callback)
  local evd = resolve_event(event)
  local replies = {}
  for _, e in ipairs(evd) do
    e.callback = callback
    self.handlers[e.id] = self.handlers[e.id] or {}
    table.insert(self.handlers[e.id], e)
    if not self.subscribed_to[e.name] then
      local raw = json.encode({ e.name })
      local reply = self:send(COMMAND.SUBSCRIBE, raw)
      table.insert(replies, reply)
      self.subscribed_to[e.name] = true
    end
  end
  return replies
end

function Connection:off(event, callback)
  local evd = resolve_event(event)
  local nremoved = 0
  for _, e in ipairs(evd) do
    local new_handlers = {}
    for _, h in ipairs(self.handlers[e.id]) do
      if
        (callback ~= nil and e.callback ~= callback)
        and (e.change ~= nil and e.change ~= h.change)
      then
        table.insert(new_handlers, h)
      end
    end
    if #new_handlers > 0 then
      nremoved = nremoved + (#self.handlers[e.id] - #new_handlers)
      self.handlers[e.id] = new_handlers
    else
      nremoved = nremoved + #self.handlers[e.id]
      self.handlers[e.id] = nil
    end
  end
  if not self:_has_subscriptions() and self.main_finished then
    self:_stop()
  end
  return nremoved
end

function Connection:once(event, callback)
  local function handler(...)
    callback(...)
    local nremoved = self:off(event, handler)
    assert(nremoved > 0)
  end
  self:on(event, handler)
end

function Connection:_has_subscriptions()
  for _, h in pairs(self.handlers) do
    if #h > 0 then return true end
  end
  return false
end

function Connection:_stop()
  self.pipe:read_stop()
  uv.stop()
end

function Connection:command(command)
  return self:send(COMMAND.RUN_COMMAND, command)
end

function Connection:get_tree()
  local tree = self:send(COMMAND.GET_TREE)
  return wrap_node(tree)
end

-- Generate get_* methods for Connection
for method, cmd in pairs(COMMAND) do
  if method:match("^GET_") and method ~= "GET_TREE" then
    Connection[method:lower()] = function(ipc)
      return ipc:send(cmd)
    end
  end
end

function Connection:main(fn)
  coroutine.wrap(function()
    self:connect_socket()
    fn(self)
    if self:_has_subscriptions() then
      self.main_finished = true
    else
      self:_stop()
    end
  end)()
  local function handle_signal(signal)
    print("Received signal "..signal)
    self:_stop()
  end
  for _, signal in ipairs {"sigint", "sigterm"} do
    local s = uv.new_signal()
    s:start(signal, handle_signal)
  end
  uv.run()
end

local function main(fn)
  local conn = Connection:new()
  conn:main(fn)
end

return {
  Connection = Connection,
  main = main,
  COMMAND = COMMAND,
  EVENT = EVENT,
  wrap_node = wrap_node,
  Cmd = Cmd,
}
