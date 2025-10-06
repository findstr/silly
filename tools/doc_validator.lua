#!./silly
local function extract_code_blocks(md_path)
	local f = assert(io.open(md_path, "r"))
	local content = f:read("*a")
	f:close()
	local blocks = {}
	for code in string.gmatch(content, "```lua validate%s*\n(.-)\n```") do
		blocks[#blocks + 1] = code
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
		print(string.format("\n\27[36m 代码块:\n %s \n\27[0m", block))
		local success, result = sandbox_exec(block)
		if success then
			print("\27[32m[通过] 执行成功\27[0m")
		else
			print("\27[31m[失败] " .. result .. "\27[0m")
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

local names = robust_find_md("./docs/src")
for _, name in pairs(names) do
	validate_md(name)
end

print("------------------------------------")
if next(fail_docs) then
	print("\n\27[31m验证失败文档:\27[0m")
	for name in pairs(fail_docs) do
		print(name)
	end
end
