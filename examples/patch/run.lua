local M = {}
local a, b = 1, 1

function M.foo()
	a = a + 1
end

function M.bar()
	b = b + 1
end

function M.dump()
	return a, b
end

return M

