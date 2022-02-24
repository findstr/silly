local crypto = require "sys.crypto"
local hpack = require "http2.hpack"
local testaux = require "testaux"
local send_hpack = hpack.new(4096)
local prefix = crypto.randomkey(200)
local unit = 250+32
return function()

	local idx =  0
	local n = 4096//unit
	print("n", n)
	local prun_count = 0
	repeat
		prun_count = prun_count + n
	until prun_count > (prun_count // 2) and prun_count > 64
	local data = {}
	for i = 1, prun_count + 32 do
		idx = idx + 1
		data[i] = prefix .. string.format("%045d", idx)
	end
	for i = 1, prun_count do
		hpack.pack(send_hpack, nil, ":path", data[i])
	end
	local evict_count = hpack.dbg_evictcount(send_hpack)
	testaux.asserteq(evict_count, (prun_count // n - 1) * n, "hpack queue is full")
	hpack.pack(send_hpack, nil,
		":path", data[prun_count-3],
		":path", data[prun_count-2],
		":path", data[prun_count-1],
		":path", data[prun_count+1])
	local evict_count = hpack.dbg_evictcount(send_hpack)
	testaux.asserteq(evict_count, 0, "hpack queue is prune")
	local id1 = hpack.dbg_stringid(send_hpack, ":path", data[prun_count])
	local id2 = hpack.dbg_stringid(send_hpack, ":path", data[prun_count+1])
	testaux.asserteq((id1 + 1), id2, "hpack prune")
end

