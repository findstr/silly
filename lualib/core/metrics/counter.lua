local labels = require "core.metrics.labels"
local helper = require "core.metrics.helper"

local mt
local label_mt

mt = {
	__index = nil,
	new = nil,
	collect = helper.collect,
	add = helper.add,
	inc = helper.inc,
}

label_mt = {
	__index = nil,
	new = nil,
	collect = helper.collect,
	labels = labels({__index = {
		add = helper.add,
		inc = helper.inc,
	}})
}

local new = helper.new("counter", {__index = mt}, {__index = label_mt})

mt.new = new
label_mt.new = new

mt.__index = mt
label_mt.__index = label_mt

return new
