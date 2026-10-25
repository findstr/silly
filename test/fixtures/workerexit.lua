local silly = require "silly"
local env = require "silly.env"
local errno = require "silly.errno"
local c = require "test.aux.c"

local mode = assert(env.get("scenario"))
if mode == "registryerror" then
	local function check_error()
		local eof, first, second, success = c.debugctrl("worker.error")
		assert(eof == errno.EOF)
		assert(type(first) == "string" and first == second)
		assert(success == nil)
	end
	check_error()
	_G.worker_error_guard = setmetatable({}, {
		__gc = function()
			check_error()
			print("REGISTRY_ERROR_GC_OK")
		end,
	})
elseif mode == "workerreset" then
	local seen = false
	local id = c.debugctrl("worker.messages")
	silly.register(id, function()
		if seen then
			print("WORKER_RESET_STALE_CALLBACK")
			return
		end
		seen = true
		require("silly.c").exit(0)
		print("WORKER_RESET_DONE")
	end)
else
	error("unknown worker exit scenario: " .. mode)
end

print("WORKER_EXIT_READY:" .. mode)
if mode ~= "workerreset" then
	silly.exit(0)
end
