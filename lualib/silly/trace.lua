local task = require "silly.task"

local M = {
	setnode = task._tracesetnode,
	spawn = task._tracespawn,
	attach = task._traceattach,
	propagate = task._tracepropagate,
}

return M
