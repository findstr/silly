---@class silly.adt.list
---@field count integer
---@field head any
---@field tail any
---@field prev table<any, any>
---@field next table<any, any>
---@field present table<any, boolean>
local M = {}
local mt = { __index = M }

local pairs = pairs

function M.new()
	---@type silly.adt.list
	local list = {
		count = 0,
		head = nil,
		tail = nil,
		prev = {},
		next = {},
		present = {},
	}
	setmetatable(list, mt)
	return list
end

---@param self silly.adt.list
---@param v any
function M:pushback(v)
	if v == nil then
		error("value cannot be nil", 2)
	end
	local present = self.present
	if present[v] then
		error("value duplicated")
	end
	local tail = self.tail
	if not tail then
		self.head, self.tail = v, v
	else
		self.prev[v] = tail
		self.next[tail] = v
		self.tail = v
	end
	present[v] = true
	self.count = self.count + 1
end

---@param self silly.adt.list
---@param v any
function M:pushfront(v)
	if v == nil then
		error("value cannot be nil", 2)
	end
	local present = self.present
	if present[v] then
		error("value duplicated")
	end
	local head = self.head
	if not head then
		self.head, self.tail = v, v
	else
		self.next[v] = head
		self.prev[head] = v
		self.head = v
	end
	present[v] = true
	self.count = self.count + 1
end

---@param self silly.adt.list
local function remove(self, v)
	local present = self.present
	if not present[v] then
		return nil, "removed"
	end
	local prev = self.prev
	local next = self.next
	local p, n = prev[v], next[v]
	if p then
		prev[v] = nil
		next[p] = n
	else
		self.head = n
	end
	if n then
		next[v] = nil
		prev[n] = p
	else
		self.tail = p
	end
	self.count = self.count - 1
	present[v] = nil
end

M.remove = remove

---@param self silly.adt.list
function M:popfront()
	local head = self.head
	if head then
		remove(self, head)
	end
	return head
end

---@param self silly.adt.list
function M:popback()
	local tail = self.tail
	if tail then
		remove(self, tail)
	end
	return tail
end


---@param self silly.adt.list
function M:clear()
	self.head, self.tail = nil, nil
	local t = self.next
	for k, _ in pairs(t) do
		t[k] = nil
	end
	t = self.prev
	for k, _ in pairs(t) do
		t[k] = nil
	end
	t = self.present
	for k, _ in pairs(t) do
		t[k] = nil
	end
	self.count = 0
end

---@param self silly.adt.list
function M:size()
	return self.count
end

---@param self silly.adt.list
function M:front()
	return self.head
end

---@param self silly.adt.list
function M:back()
	return self.tail
end

---@param list silly.adt.list
---@param val any
local function value_iter(list, val)
	if not val then
		return list.head
	end
	return list.next[val]
end

---@param self silly.adt.list
function M:values()
	return value_iter, self, nil
end

return M