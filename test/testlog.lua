local core = require("core")
local log = require("log")


local l = log.open("test.log")

log.add(l, "Error", "Hello")
log.add(l, "Warning", "World")


log.close(l)

print("test log ok")

