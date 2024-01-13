local M = {}
STEP = 3
local a, b = 1, 1

function M.foo()
	STEP = 4
	a = a + STEP
	b = b + STEP
end

function M.bar()
	b = b + 1
end

function M.dump()
	return a, b
end

return M

