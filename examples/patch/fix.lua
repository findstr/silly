local M = {}
step = 3
local a, b = 1, 1

function M.foo()
	step = 4
	a = a + step
	b = b + step
end

function M.bar()
	b = b + 1
end

function M.dump()
	return a, b
end

return M

