#!/usr/bin/env luajit
-- Switch to prev/next tab in topmost tabbed layout
local i3 = require("i3ipc")
local ipc = i3.Connection:new()
ipc:main(function()
  local ret = ipc:get_inputs()
  print(require("inspect")(ret))
  ipc:on("window", function(_, event)
    print(require("inspect")(event))
  end)
end)
