local silly = require "silly"
local hive = require "silly.hive"
local testaux = require "test.testaux"

local binary = os.getenv("SILLY_BIN") or (silly.multiplexer == "iocp" and "./silly.exe" or "./silly")
local cpath = os.getenv("SILLY_LUACLIB_PATH") or "luaclib"
local worker = hive.spawn [[
	return function(command)
		local process = assert(io.popen(command))
		local output = process:read("*a")
		local ok, reason, code = process:close()
		return {output = output, ok = ok, reason = reason, code = code}
	end
]]

for _, spec in ipairs({
	{id = 5, mode = "registryerror", name = "Error lookup works across coroutine and main-thread frames"},
	{id = 6, mode = "workerreset", name = "Worker reset clears callbacks from a nested main-thread call"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local command = string.format(
			'"%s" test/fixtures/workerexit.lua --scenario=%s --lualib-cpath="./%s/?.so;./%s/?.dll" 2>&1',
			binary, spec.mode, cpath, cpath)
		local result = hive.invoke(worker, command)
		local output = result.output
		assert(result.ok, output)
		assert(output:find("WORKER_EXIT_READY:" .. spec.mode, 1, true), output)
		assert(output:find("exit, leak memory size:0\n", 1, true), output)
		assert(not output:find("ERROR: ", 1, true), output)
		assert(not output:find("runtime error:", 1, true), output)
		assert(not output:find("error in __gc", 1, true), output)
		if spec.mode == "registryerror" then
			assert(output:find("REGISTRY_ERROR_GC_OK", 1, true), output)
		else
			assert(output:find("WORKER_RESET_DONE", 1, true), output)
			assert(not output:find("WORKER_RESET_STALE_CALLBACK", 1, true), output)
		end
		testaux.success("Test " .. spec.id .. ": Child exits with consistent worker state")
	end)
end
