#!./silly
local silly = require "silly"
local function extract_code_blocks(md_path)
	local f = assert(io.open(md_path, "r"))
	local content = f:read("*a")
	f:close()
	local blocks = {}

	-- Use a more robust pattern that searches for code blocks sequentially
	local i = 1
	while true do
		-- Find the start of a lua validate code block
		local start_pos, end_pos = string.find(content, "```lua validate%s*\n", i)
		if not start_pos then
			break
		end

		-- Find the closing ``` (with optional leading whitespace on its line)
		local code_start = end_pos + 1
		local close_pos = string.find(content, "\n%s*```", code_start)

		if not close_pos then
			-- No closing found, skip this block
			break
		end

		-- Extract the code between the markers
		local code = string.sub(content, code_start, close_pos - 1)
		blocks[#blocks + 1] = code

		-- Move past this code block (find the actual position after ```)
		local _, backtick_end = string.find(content, "```", close_pos + 1)
		i = backtick_end + 1
	end
	return blocks
end

local function sandbox_exec(code)
	local chunk, err = load(code, "chunk", "t")
	if not chunk then
		return false, err
	end
	return pcall(chunk)
end

local fail_docs = {}

local function validate_md(md_file)
	print("\n\27[34m验证文档:", md_file, "\27[0m")
	for i, block in ipairs(extract_code_blocks(md_file)) do
		local success, result = sandbox_exec(block)
		if success then
			--print(string.format("\n\27[36m 代码块:\n %s \n\27[0m", block))
			--print("\27[32m[通过] 执行成功\27[0m")
		else
			print("\27[31m[失败] " .. result .. ":" ..  block .. ":" .. "\27[0m")
			fail_docs[md_file] = true
		end
	end
end

local function robust_find_md(root)
	local is_windows = package.config:sub(1, 1) == '\\'
	local safe_path = root:gsub('"', '\\"')

	local cmd
	if is_windows then
		cmd = string.format('chcp  65001 >nul && dir /s/b/a:-d "%s\\*.md" 2>nul\n', safe_path)
	else
		cmd = string.format('find  "%s" -type f -name "*.md" 2>/dev/null\n', safe_path)
	end

	local handle = io.popen(cmd)
	if not handle then return {} end

	local results = {}
	while true do
		local line = handle:read("*l")
		if not line then break end

		if is_windows then
			line = line:gsub("\\", "/"):gsub("\r", "")
		end
		table.insert(results, line)
	end
	handle:close()

	return results
end

local time = require "silly.time"
local names = robust_find_md("./docs/src")
for _, name in pairs(names) do
	validate_md(name)
	time.sleep(500)
	local name = next(fail_docs)
	if name then
		print(name)
		return
	end
end

if next(fail_docs) then
	print("\n\27[31m验证失败文档:\27[0m")
	for name in pairs(fail_docs) do
		print(name)
	end
end
silly.exit()

