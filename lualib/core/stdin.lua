local core = require "core"
local mutex = require "core.sync.mutex":new()
local logger = require "core.logger"
local ipairs = ipairs
local tonumber = tonumber
local unpack = table.unpack
local concat = table.concat
local remove = table.remove
local move = table.move
local key = "stdin"

---@type thread|nil
local waiting = nil

local EOF = {}
local lines = {}
local buf = {}

local M = {}

function M:__close()
	-- do nothing
end
function M:close()
	-- do nothing
end

function M:flush()
	logger.error("can't flush stdin")
end

function M:seek(whence, offset)
	logger.error("can't seek stdin")
end

function M:setvbuf(mode, size)
	logger.error("can't setvbuf stdin")
end

function M:write(...)
	logger.error("can't write stdin")
end

local function read_number()
	local line = ""
	local pos = 1
	repeat
		while #lines == 0 do
			waiting = core.running()
			core.wait()
		end
		line = lines[1]
		if line == EOF then
			return nil
		end
		-- 跳过空白字符
		local space_pattern = "^%s+"
		local spaces = line:match(space_pattern, pos) or ""
		if #spaces < #line then
			break
		end
		remove(lines, 1)
	until #lines > 0
	-- 读取可选的符号
	local sign_pattern = "^[-+]?"
	local sign = line:match(sign_pattern, pos) or ""
	pos = pos + #sign
	buf[#buf + 1] = sign
	-- 检查是否是十六进制
	local is_hex = false
	local hex_prefix = line:match("^0[xX]", pos)
	if hex_prefix then
	    is_hex = true
	    pos = pos + 2
	    buf[#buf + 1] = hex_prefix
	end
	-- 读取整数部分
	local digit_pattern = is_hex and "^[0-9a-fA-F]+" or "^%d+"
	local digits = line:match(digit_pattern, pos) or ""
	pos = pos + #digits
	buf[#buf + 1] = digits
	-- 读取小数部分
	if line:match("^[.]", pos) then
	    local decimal = "."
	    pos = pos + 1
	    buf[#buf + 1] = decimal

	    digits = line:match(digit_pattern, pos) or ""
	    pos = pos + #digits
	    buf[#buf + 1] = digits
	end
	-- 读取指数部分
	local exp_pattern = is_hex and "^[pP]" or "^[eE]"
	local exp_mark = line:match(exp_pattern, pos)
	if exp_mark and (#buf > 0) then
	    pos = pos + 1
	    buf[#buf + 1] = exp_mark
	    -- 指数的符号
	    sign = line:match("^[-+]", pos) or ""
	    pos = pos + #sign
	    buf[#buf + 1] = sign
	    -- 指数的数字
	    digits = line:match("^%d+", pos) or ""
	    pos = pos + #digits
	    buf[#buf + 1] = digits
	end
	if pos <= #line then
		lines[1] = line:sub(pos)
	else
		remove(lines, 1)
	end
	local num_str = concat(buf)
	for i = 1, #buf do
		buf[i] = nil
	end
	-- 验证并转换数字
	if #num_str == 0 or #num_str > 200 then
		return nil
	end
	return (tonumber(num_str))
end

local function read_all()
	while lines[#lines] ~= EOF do
		waiting = core.running()
		core.wait()
	end
	local str = concat(lines, "", 1, #lines - 1)
	for i = 1, #lines do
		lines[i] = nil
	end
	lines[1] = EOF
	return str
end

local function read_line(chop)
	return function()
		while #lines == 0 do
			waiting = core.running()
			core.wait()
		end
		local line = lines[1]
		if line == EOF then
			return nil
		end
		remove(lines, 1)
		return chop and line:sub(1, -2) or line
	end
end

local function read_chars(n)
	local count = 0
	while lines[1] ~= EOF do
		while #lines == 0 do
			waiting = core.running()
			core.wait()
		end
		local line = lines[1]
		if count + #line >= n then
			local left = n - count
			lines[1] = line:sub(left + 1)
			buf[#buf + 1] = line:sub(1, left)
			local str = concat(buf)
			for j = 1, #buf do
				buf[j] = nil
			end
			return str
		end
		remove(lines, 1)
		buf[#buf + 1] = line
		count = count + #line
	end
end

local read_fn = {
	n = read_number,
	a = read_all,
	l = read_line(true),
	L = read_line(false),
}

function M:read(...)
	mutex:lock(key)
	local args = {...}
        if #args == 0 then
            args = {"l"} -- 默认格式
        end
        local results = {}
        for _, format in ipairs(args) do
            local result
	    local fn = read_fn[format]
	    if fn then
		result = fn()
	    elseif type(format) == "number" then
		result = read_chars(format)
	    else
		logger.error("[stdin] invalid format: ", format)
	    end
	    if result == nil then
		return nil
	    end
	    results[#results + 1] = result
	end
	return unpack(results)
end

local function lines_iter(args)
	return M:read(unpack(args))
end

function M:lines(...)
	local args = {...}
	if #args == 0 then
		args = {"l"}
	end
	return lines_iter, args, nil
end

local function dispatch(data)
	data = data or EOF
	lines[#lines + 1] = data
	if waiting then
		core.wakeup(waiting)
		waiting = nil
	end
end

io.stdin = M

core.stdin(dispatch)

return M
