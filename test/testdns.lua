local dns = require "silly.net.dns"
local task = require "silly.task"
local time = require "silly.time"
local mock = require "test.mock_dns_server"
local testaux = require "test.testaux"
local channel = require "silly.sync.channel"

local PORT = 15353
local server = mock.new(PORT)
server:start()
dns.conf { nameservers = {"127.0.0.1:" .. PORT} }

-----------------------------------------------------------------
testaux.case("Test 1: Basic A record", function()
	server:set_handler(function(query, respond)
		if query.name == "t1.mock.test" and query.qtype == mock.A then
			respond({
				answers = {
					{type = mock.A, rdata = "1.2.3.4", ttl = 10},
				},
			})
		end
	end)
	local ip = dns.lookup("t1.mock.test", dns.A)
	testaux.asserteq(ip, "1.2.3.4", "Test 1.1: A record lookup")
end)

-----------------------------------------------------------------
testaux.case("Test 2: AAAA record format", function()
	server:set_handler(function(query, respond)
		if query.name == "t2.mock.test" and query.qtype == mock.AAAA then
			respond({
				answers = {
					{type = mock.AAAA,
					 rdata = "2001:0db8:0000:0000:0000:0000:0000:0001",
					 ttl = 10},
				},
			})
		end
	end)
	local ip = dns.lookup("t2.mock.test", dns.AAAA)
	-- inet_ntop produces RFC 5952 canonical form
	testaux.asserteq(ip, "2001:db8::1",
		"Test 2.1: AAAA should use canonical IPv6 format")
end)

-----------------------------------------------------------------
testaux.case("Test 3: CNAME following", function()
	server:set_handler(function(query, respond)
		if query.name == "t3.mock.test" and query.qtype == mock.A then
			-- Return ONLY the CNAME, not the A record for target
			-- This requires the client to follow the CNAME chain
			respond({
				answers = {
					{type = mock.CNAME, name = "t3.mock.test",
					 rdata = "t3-real.mock.test", ttl = 10},
				},
			})
		elseif query.name == "t3-real.mock.test" and query.qtype == mock.A then
			-- Return the A record when client queries the target
			respond({
				answers = {
					{type = mock.A, rdata = "5.6.7.8", ttl = 10},
				},
			})
		end
	end)
	local ip = dns.lookup("t3.mock.test", dns.A)
	-- so resolve can't recursively query the target
	testaux.asserteq(ip, "5.6.7.8",
		"Test 3.1: CNAME-only response should trigger target query")
end)

-----------------------------------------------------------------
testaux.case("Test 4: Receive loop survives stale response", function()
	-- Strategy: query t4a with very short timeout so retries exhaust quickly,
	-- save the respond function, then send a stale response to kill the loop.
	local stale_respond = nil
	server:set_handler(function(query, respond)
		if query.name == "t4a.mock.test" then
			if not stale_respond then
				stale_respond = respond
			end
			-- Don't respond - let the client timeout on all retries
		elseif query.name == "t4b.mock.test" then
			respond({
				answers = {
					{type = mock.A, rdata = "10.10.10.10", ttl = 10},
				},
			})
		end
	end)
	-- Short timeout so retries exhaust quickly
	local ip = dns.lookup("t4a.mock.test", dns.A, 100)
	testaux.asserteq(ip, nil,
		"Test 4.1: First query should timeout")
	-- Now send a stale response - this triggers `return` on line 310
	-- which kills the receive loop
	assert(stale_respond, "should have captured respond function")
	stale_respond({
		answers = {
			{type = mock.A, rdata = "9.9.9.9", ttl = 10},
		},
	})
	time.sleep(100) -- let stale response be processed
	local ip2 = dns.lookup("t4b.mock.test", dns.A, 2000)
	testaux.assertneq(ip2, nil,
		"Test 4.2: Second query should succeed (receive loop alive)")
	testaux.asserteq(ip2, "10.10.10.10",
		"Test 4.3: Second query returns correct IP")
end)

-----------------------------------------------------------------
testaux.case("Test 5: Session ID wraparound", function()
	-- This tests that session IDs don't collide
	-- (never 0, and 65535+1 wraps to 1) - ID space is 65535 not 65536
	-- After fix: session = session % 65536 gives IDs 0..65535 (full 16-bit range)
	-- We just verify that queries work after many iterations
	local resolved_count = 0
	server:set_handler(function(query, respond)
		respond({
			answers = {
				{type = mock.A, rdata = "11.11.11.11", ttl = 0},
			},
		})
	end)
	-- Do several queries to exercise session ID generation
	for i = 1, 10 do
		local name = "t5-" .. i .. ".mock.test"
		local ip = dns.lookup(name, dns.A, 2000)
		if ip then
			resolved_count = resolved_count + 1
		end
	end
	testaux.asserteq(resolved_count, 10,
		"Test 5.1: All queries should resolve")
end)

-----------------------------------------------------------------
testaux.case("Test 6: dns.conf() reset", function()
	-- First ensure we have an active connection to server1
	server:set_handler(function(query, respond)
		respond({
			answers = {
				{type = mock.A, rdata = "11.11.11.11", ttl = 10},
			},
		})
	end)
	local warmup = dns.lookup("t6-warmup.mock.test", dns.A, 2000)
	testaux.asserteq(warmup, "11.11.11.11",
		"Test 6.1: Warmup query to server1")
	-- Now start a second mock server on a different port
	local PORT2 = 15354
	local server2 = mock.new(PORT2)
	server2:start()
	local server2_hit = false
	server2:set_handler(function(query, respond)
		server2_hit = true
		respond({
			answers = {
				{type = mock.A, rdata = "22.22.22.22", ttl = 10},
			},
		})
	end)
	-- Switch DNS to server2
	dns.conf { nameservers = {"127.0.0.1:" .. PORT2} }
	local ip = dns.lookup("t6.mock.test", dns.A, 2000)
	-- After fix: dns.conf() closes old fd, new query connects to server2
	testaux.asserteq(server2_hit, true,
		"Test 6.2: Query should hit server2 after dns.conf() switch")
	testaux.asserteq(ip, "22.22.22.22",
		"Test 6.3: Should get response from server2")
	server2:stop()
	-- Switch back to server1 for remaining tests
	dns.conf { nameservers = {"127.0.0.1:" .. PORT} }
end)

-----------------------------------------------------------------
testaux.case("Test 7: RCODE handling", function()
	server:set_handler(function(query, respond)
		if query.name == "t7.mock.test" then
			respond({
				rcode = 3, -- NXDOMAIN
				answers = {},
			})
		elseif query.name == "t7b.mock.test" then
			respond({
				-- rcode = 0 (NOERROR, default)
				answers = {},
			})
		end
	end)
	local ip = dns.lookup("t7.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 7.1: NXDOMAIN should return nil")
	local ip2 = dns.lookup("t7b.mock.test", dns.A, 2000)
	testaux.asserteq(ip2, nil,
		"Test 7.2: NOERROR empty response should return nil")
end)

-----------------------------------------------------------------
testaux.case("Test 8: TC bit triggers TCP fallback", function()
	server:set_handler(function(query, respond)
		if query.name == "t8.mock.test" then
			if query.transport == "udp" then
				-- UDP: respond with TC=1 (truncated)
				respond({
					tc = true,
					answers = {},
				})
			else
				-- TCP: respond with full answer
				respond({
					answers = {
						{type = mock.A, rdata = "33.33.33.33", ttl = 10},
					},
				})
			end
		end
	end)
	local ip = dns.lookup("t8.mock.test", dns.A, 2000)
	testaux.asserteq(ip, "33.33.33.33",
		"Test 8.1: TC response should trigger TCP fallback and resolve")
end)

-----------------------------------------------------------------
testaux.case("Test 9: Compression pointer loop", function()
	server:set_handler(function(query, respond, respond_raw)
		if query.name == "t9.mock.test" then
			-- Craft a response with circular compression pointers
			-- Header (12 bytes)
			local header = string.pack(">I2I2I2I2I2I2",
				query.id,
				0x8180, -- standard response flags
				1,      -- QDCOUNT
				1,      -- ANCOUNT
				0, 0)
			-- Question section (echo from query)
			local question = query.raw:sub(query.question_start, query.question_end)
			-- Answer: name using pointer, then RDATA with circular pointer
			local answer_name = "\xc0\x0c" -- pointer to question QNAME
			local answer_meta = string.pack(">I2I2I4", mock.CNAME, 1, 300)
			-- RDATA: a CNAME whose name is a pointer that points to
			-- itself (the RDATA starts at a known offset)
			-- Calculate offset of RDATA
			local rdata_offset = #header + #question + #answer_name + #answer_meta + 2
			-- Create circular pointer: point to rdata_offset
			local ptr_hi = 0xC0 | ((rdata_offset >> 8) & 0x3F)
			local ptr_lo = rdata_offset & 0xFF
			local rdata = string.char(ptr_hi, ptr_lo)
			local rdlen = string.pack(">I2", #rdata)
			local raw = header .. question .. answer_name .. answer_meta .. rdlen .. rdata
			respond_raw(raw)
		end
	end)
	-- After fix: detect loop via depth counter and return error
	-- We just verify it doesn't hang (if it hangs, test timeout catches it)
	local ip = dns.lookup("t9.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 9.1: Circular pointer should not hang")
end)

-----------------------------------------------------------------
testaux.case("Test 10: Response ID matching", function()
	local sync_ch = channel.new()
	server:set_handler(function(query, respond, respond_raw)
		if query.name == "t10.mock.test" then
			-- Send a response with wrong ID first
			local fake_query = {
				id = query.id ~ 0xFFFF,
				name = query.name,
				raw = query.raw,
				question_start = query.question_start,
				question_end = query.question_end,
			}
			local wrong_id_response = mock.build_response(fake_query,
				{answers = {{type = mock.A, rdata = "99.99.99.99", ttl = 10}}}
			)
			respond_raw(wrong_id_response)
			-- Then send correct response
			task.fork(function()
				time.sleep(100)
				local correct = mock.build_response(query, {
					answers = {{type = mock.A, rdata = "44.44.44.44", ttl = 10}},
				})
				server.conn:sendto(correct, query.client_addr)
			end)
		end
	end)
	local ip = dns.lookup("t10.mock.test", dns.A, 2000)
	-- Wrong-ID response should be ignored; correct one accepted
	-- Note: This actually works "by accident" in current code since
	-- wait_coroutine[wrong_id] won't find a coroutine
	-- But it exercises the path and validates behavior
	testaux.asserteq(ip, "44.44.44.44",
		"Test 10.1: Should accept correct ID response")
end)

-----------------------------------------------------------------
testaux.case("Test 11: QR bit validation", function()
	server:set_handler(function(query, respond)
		if query.name == "t11.mock.test" then
			-- Send response with QR=0 (query, not response)
			respond({
				qr = 0,
				answers = {
					{type = mock.A, rdata = "55.55.55.55", ttl = 10},
				},
			})
			-- Then send correct response with QR=1
			task.fork(function()
				time.sleep(100)
				local correct = mock.build_response(query, {
					qr = 1,
					answers = {{type = mock.A, rdata = "56.56.56.56", ttl = 10}},
				})
				server.conn:sendto(correct, query.client_addr)
			end)
		end
	end)
	local ip = dns.lookup("t11.mock.test", dns.A, 2000)
	-- After fix: packets with QR=0 should be rejected
	testaux.asserteq(ip, "56.56.56.56",
		"Test 11.1: Should reject QR=0 and accept QR=1")
end)

-----------------------------------------------------------------
testaux.case("Test 12: SRV record", function()
	server:set_handler(function(query, respond)
		if query.name == "t12.mock.test" and query.qtype == mock.SRV then
			respond({
				answers = {
					{type = mock.SRV, rdata = {
						priority = 10,
						weight = 20,
						port = 8080,
						target = "server1.mock.test",
					}, ttl = 10},
					{type = mock.SRV, rdata = {
						priority = 20,
						weight = 10,
						port = 9090,
						target = "server2.mock.test",
					}, ttl = 10},
				},
			})
		end
	end)
	local rr = dns.resolve("t12.mock.test", dns.SRV, 2000)
	testaux.assertneq(rr, nil, "Test 12.1: SRV resolve should return results")
	testaux.asserteq(#rr, 2, "Test 12.2: Should have 2 SRV records")
	table.sort(rr, function(a, b) return a.priority < b.priority end)
	testaux.asserteq(rr[1].priority, 10, "Test 12.3: First SRV priority")
	testaux.asserteq(rr[1].weight, 20, "Test 12.4: First SRV weight")
	testaux.asserteq(rr[1].port, 8080, "Test 12.5: First SRV port")
	testaux.asserteq(rr[1].target, "server1.mock.test", "Test 12.6: First SRV target")
	testaux.asserteq(rr[2].priority, 20, "Test 12.7: Second SRV priority")
	testaux.asserteq(rr[2].port, 9090, "Test 12.8: Second SRV port")
end)

-----------------------------------------------------------------
testaux.case("Test 13: Multi-server query, first success", function()
	local PORT2 = 15355
	local server2 = mock.new(PORT2)
	server2:start()
	local server1_hit = false
	local server2_hit = false
	local hit_ch = channel.new()
	server:set_handler(function(query, respond)
		if query.name == "t13.mock.test" then
			server1_hit = true
			respond({
				answers = {
					{type = mock.A, rdata = "13.13.13.13", ttl = 10},
				},
			})
			hit_ch:push(true)
		end
	end)
	server2:set_handler(function(query, respond)
		if query.name == "t13.mock.test" then
			server2_hit = true
			respond({
				answers = {
					{type = mock.A, rdata = "13.13.13.13", ttl = 10},
				},
			})
		end
	end)
	-- Set both servers
	dns.conf { nameservers = {"127.0.0.1:" .. PORT, "127.0.0.1:" .. PORT2}, timeout = 1, }
	local ip = dns.lookup("t13.mock.test", dns.A, 5000)
	testaux.asserteq(ip, "13.13.13.13",
		"Test 13.1: Multi-server query should resolve")
	-- lookup returns on the first response; wait for both handlers
	hit_ch:pop()
	testaux.asserteq(server1_hit, true,
		"Test 13.2: Server1 should receive query")
	testaux.asserteq(server2_hit, false,
		"Test 13.3: Server2 should not receive query")
	server2:stop()
	dns.conf { nameservers = {"127.0.0.1:" .. PORT} }
end)

-----------------------------------------------------------------
testaux.case("Test 14: Multi-server failover", function()
	local PORT2 = 15356
	local PORT3 = 15358
	local server2 = mock.new(PORT2)
	local server3 = mock.new(PORT3)
	server2:start()
	server3:start()
	-- Server1 doesn't respond
	server:set_handler(function(query, respond)
		-- no response
	end)
	server2:set_handler(function(query, respond)
		if query.name == "t14.mock.test" or query.name == "t14b.mock.test" then
			respond({
				answers = {
					{type = mock.A, rdata = "14.14.14.14", ttl = 0},
				},
			})
		end
	end)
	dns.conf { nameservers = {"127.0.0.1:" .. PORT, "127.0.0.1:" .. PORT2}, timeout = 1, attempts = 1 }
	local ip = dns.lookup("t14.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 14.1: Should get nil response from server1")
	ip = dns.lookup("t14b.mock.test", dns.A, 2000)
	testaux.asserteq(ip, "14.14.14.14",
		"Test 14.2: Should get response from server2 when server1 silent")
	-- 14.3-14.4: Recovery — server1 comes back, failcount resets, traffic returns
	local server1_hit = false
	server:set_handler(function(query, respond)
		if query.name == "t14c.mock.test" then
			server1_hit = true
			respond({
				answers = {
					{type = mock.A, rdata = "14.1.1.1", ttl = 0},
				},
			})
		end
	end)
	ip = dns.lookup("t14c.mock.test", dns.A, 2000)
	-- server2 has failcount=0 (just succeeded), server1 has failcount>0
	-- so this query should go to server2, which has failcount=0
	testaux.asserteq(server1_hit, false,
		"Test 14.3: Server1 should not be selected (failcount > 0)")
	-- After server2 success, server2 failcount stays 0.
	-- Now reconfigure to reset failcounts so server1 gets a fresh start
	dns.conf { nameservers = {"127.0.0.1:" .. PORT, "127.0.0.1:" .. PORT2}, timeout = 1, attempts = 1 }
	server1_hit = false
	ip = dns.lookup("t14c.mock.test", dns.A, 2000)
	testaux.asserteq(server1_hit, true,
		"Test 14.4: After conf reset, server1 should be selected first again")
	testaux.asserteq(ip, "14.1.1.1",
		"Test 14.5: Server1 should respond after recovery")
	-- 14.6-14.7: All servers fail then recover
	server:set_handler(function(query, respond)
		-- no response
	end)
	server2:set_handler(function(query, respond)
		-- no response
	end)
	dns.conf { nameservers = {"127.0.0.1:" .. PORT, "127.0.0.1:" .. PORT2}, timeout = 1, attempts = 1 }
	ip = dns.lookup("t14d.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 14.6: First server fails")
	ip = dns.lookup("t14e.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 14.7: Second server also fails")
	-- Now recover server2 (server1 still dead)
	server2:set_handler(function(query, respond)
		if query.name == "t14f.mock.test" then
			respond({
				answers = {
					{type = mock.A, rdata = "14.2.2.2", ttl = 0},
				},
			})
		end
	end)
	-- Both have failcount=1; resolver picks server1 (first), which still fails
	ip = dns.lookup("t14f.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 14.8: Server1 still dead (equal failcount, picked first)")
	-- Now server1.failcount=2 > server2.failcount=1 → server2 selected
	ip = dns.lookup("t14f.mock.test", dns.A, 2000)
	testaux.asserteq(ip, "14.2.2.2",
		"Test 14.9: Should recover via server2 (lower failcount)")
	-- 14.10-14.12: Failcount-based selection with 3 servers
	-- Add server3, which should have failcount=0
	server3:set_handler(function(query, respond)
		if query.name == "t14g.mock.test" then
			respond({
				answers = {
					{type = mock.A, rdata = "14.3.3.3", ttl = 0},
				},
			})
		end
	end)
	dns.conf { nameservers = {"127.0.0.1:" .. PORT, "127.0.0.1:" .. PORT2, "127.0.0.1:" .. PORT3}, timeout = 1, attempts = 1 }
	-- All failcounts are 0 after conf reset, server1 is first → selected
	server:set_handler(function(query, respond)
		-- no response (server1 fails)
	end)
	ip = dns.lookup("t14g.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 14.10: Server1 fails (failcount becomes 1)")
	-- Now server1 has failcount=1, server2 and server3 have failcount=0
	-- server2 is first with failcount=0 → should be selected
	local server3_hit = false
	server2:set_handler(function(query, respond)
		if query.name == "t14h.mock.test" then
			respond({
				answers = {
					{type = mock.A, rdata = "14.2.2.2", ttl = 0},
				},
			})
		end
	end)
	server3:set_handler(function(query, respond)
		if query.name == "t14h.mock.test" then
			server3_hit = true
			respond({
				answers = {
					{type = mock.A, rdata = "14.3.3.3", ttl = 0},
				},
			})
		end
	end)
	ip = dns.lookup("t14h.mock.test", dns.A, 2000)
	testaux.asserteq(ip, "14.2.2.2",
		"Test 14.11: Server2 (failcount=0) preferred over server1 (failcount=1)")
	testaux.asserteq(server3_hit, false,
		"Test 14.12: Server3 should not be hit (server2 selected first)")
	server2:stop()
	server3:stop()
	dns.conf { nameservers = {"127.0.0.1:" .. PORT} }
end)

-----------------------------------------------------------------
testaux.case("Test 15: Singleflight dedup in DNS", function()
	local query_count = 0
	server:set_handler(function(query, respond)
		if query.name == "t15.mock.test" then
			query_count = query_count + 1
			time.sleep(200) -- slow response to allow dedup
			respond({
				answers = {
					{type = mock.A, rdata = "15.15.15.15", ttl = 10},
				},
			})
		end
	end)
	local results = {}
	local done_ch = channel.new()
	-- Launch 5 concurrent lookups for same domain
	for i = 1, 5 do
		task.fork(function()
			results[i] = dns.lookup("t15.mock.test", dns.A, 5000)
			done_ch:push(i)
		end)
	end
	for _ = 1, 5 do
		done_ch:pop()
	end
	-- All should get the same result
	for i = 1, 5 do
		testaux.asserteq(results[i], "15.15.15.15",
			"Test 15." .. i .. ": Caller " .. i .. " gets result")
	end
	-- Mock server should only see 1 query (singleflight dedup)
	testaux.asserteq(query_count, 1,
		"Test 15.6: Server should receive only 1 query (singleflight)")
end)

-----------------------------------------------------------------
testaux.case("Test 16: Search list", function()
	server:set_handler(function(query, respond)
		if query.name == "myhost.mock.test" and query.qtype == mock.A then
			respond({
				answers = {
					{type = mock.A, rdata = "16.16.16.16", ttl = 10},
				},
			})
		end
	end)
	dns.conf { nameservers = {"127.0.0.1:" .. PORT}, search = {"mock.test"} }
	local ip = dns.lookup("myhost", dns.A, 2000)
	testaux.asserteq(ip, "16.16.16.16",
		"Test 16.1: Short name resolved via search suffix")
	dns.conf { nameservers = {"127.0.0.1:" .. PORT} }
end)

-----------------------------------------------------------------
testaux.case("Test 17: dns.conf() with list", function()
	local PORT2 = 15357
	local server2 = mock.new(PORT2)
	server2:start()
	local hit_count = 0
	local hit_ch = channel.new()
	server:set_handler(function(query, respond)
		if query.name == "t17.mock.test" then
			hit_count = hit_count + 1
			hit_ch:push(true)
		end
	end)
	server2:set_handler(function(query, respond)
		if query.name == "t17.mock.test" then
			hit_count = hit_count + 1
			respond({
				answers = {
					{type = mock.A, rdata = "17.17.17.17", ttl = 10},
				},
			})
			hit_ch:push(true)
		end
	end)
	dns.conf { nameservers = {"127.0.0.1:" .. PORT, "127.0.0.1:" .. PORT2}, timeout=1, attempts=1 }
	local ip = dns.lookup("t17.mock.test", dns.A, 2000)
	ip = dns.lookup("t17.mock.test", dns.A, 2000)
	testaux.asserteq(ip, "17.17.17.17",
		"Test 17.1: dns.server with list should work")
	-- lookup returns on the first response; wait for both handlers
	hit_ch:pop()
	hit_ch:pop()
	testaux.asserteq(hit_count, 2,
		"Test 17.2: Both servers should receive query")
	server2:stop()
	dns.conf { nameservers = {"127.0.0.1:" .. PORT} }
end)

-----------------------------------------------------------------
testaux.case("Test 18: QNAME length validation", function()
	server:set_handler(function(query, respond)
		-- Should never be called for invalid names
		respond({
			answers = {
				{type = mock.A, rdata = "18.18.18.18", ttl = 10},
			},
		})
	end)
	-- 18.1: Label > 63 chars
	local long_label = string.rep("a", 64) .. ".mock.test"
	local ip = dns.lookup(long_label, dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 18.1: Label > 63 chars should return nil")
	-- 18.2: Total name > 253 chars
	-- Build a name with valid labels but total > 253
	local parts = {}
	for i = 1, 43 do -- 43 * (5+1) = 258 > 253 (each "aaaaa." is 6 chars)
		parts[#parts + 1] = "aaaaa"
	end
	local long_name = table.concat(parts, ".")
	local ip2 = dns.lookup(long_name, dns.A, 2000)
	testaux.asserteq(ip2, nil,
		"Test 18.2: Name > 253 chars should return nil")
	-- 18.3: Valid name still works
	local ip3 = dns.lookup("t18.mock.test", dns.A, 2000)
	testaux.asserteq(ip3, "18.18.18.18",
		"Test 18.3: Valid name should still resolve")
end)

-----------------------------------------------------------------
testaux.case("Test 19: Hosts file IP validation", function()
	-- 19.1: Valid IPv4 in hosts
	dns.sethosts("10.20.30.40 t19v4.mock.test\n")
	local ip = dns.lookup("t19v4.mock.test", dns.A)
	testaux.asserteq(ip, "10.20.30.40",
		"Test 19.1: Valid IPv4 in hosts should resolve")
	-- 19.2: Valid IPv6 in hosts
	dns.sethosts("::1 t19v6.mock.test\n")
	local ip6 = dns.lookup("t19v6.mock.test", dns.AAAA)
	testaux.asserteq(ip6, "::1",
		"Test 19.2: Valid IPv6 in hosts should resolve")
	-- 19.3: Invalid entries should be ignored
	-- "cafe:babe" passes the IP regex (all hex + colon) and isv6() check
	-- but is not a valid IPv6 address - should be ignored
	dns.sethosts("cafe:babe t19bad.mock.test\n")
	local ip_bad = dns.lookup("t19bad.mock.test", dns.AAAA)
	testaux.asserteq(ip_bad, nil,
		"Test 19.3: Invalid IP in hosts should be ignored")
end)

-----------------------------------------------------------------
testaux.case("Test 20: Case-insensitive domain names", function()
	local query_count = 0
	server:set_handler(function(query, respond)
		-- Handler should receive lowercase name after normalization
		if query.name == "t20.mock.test" and query.qtype == mock.A then
			query_count = query_count + 1
			respond({
				answers = {
					{type = mock.A, rdata = "20.20.20.20", ttl = 60},
				},
			})
		end
	end)
	-- 20.1: Query with mixed case
	local ip = dns.lookup("T20.Mock.Test", dns.A, 2000)
	testaux.asserteq(ip, "20.20.20.20",
		"Test 20.1: Mixed case query should resolve")
	-- 20.2: Query with lowercase should hit cache (not server)
	local ip2 = dns.lookup("t20.mock.test", dns.A, 2000)
	testaux.asserteq(ip2, "20.20.20.20",
		"Test 20.2: Lowercase query should also resolve")
	testaux.asserteq(query_count, 1,
		"Test 20.3: Server should be hit only once (cache hit for second)")
end)

-----------------------------------------------------------------
testaux.case("Test 21: Negative caching", function()
	local query_count = 0
	server:set_handler(function(query, respond)
		if query.name == "t21.mock.test" then
			query_count = query_count + 1
			respond({
				rcode = 3, -- NXDOMAIN
				answers = {},
			})
		end
	end)
	-- 21.1: Query non-existent name
	local ip = dns.lookup("t21.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 21.1: NXDOMAIN should return nil")
	testaux.asserteq(query_count, 1,
		"Test 21.2: First query should hit server")
	-- 21.2: Query same name again immediately - should be negative-cached
	local ip2 = dns.lookup("t21.mock.test", dns.A, 2000)
	testaux.asserteq(ip2, nil,
		"Test 21.3: Second query should also return nil")
	testaux.asserteq(query_count, 1,
		"Test 21.4: Server should NOT be hit again (negative cached)")
end)

-----------------------------------------------------------------
testaux.case("Test 22: Additional section parsing", function()
	local a_query_count = 0
	server:set_handler(function(query, respond)
		if query.name == "t22.mock.test" and query.qtype == mock.SRV then
			-- SRV response with glue A record in additional section
			respond({
				answers = {
					{type = mock.SRV, rdata = {
						priority = 10,
						weight = 20,
						port = 8080,
						target = "t22-target.mock.test",
					}, ttl = 60},
				},
				additional = {
					{type = mock.A, name = "t22-target.mock.test",
					 rdata = "22.22.22.22", ttl = 60},
				},
			})
		elseif query.name == "t22-target.mock.test" and query.qtype == mock.A then
			a_query_count = a_query_count + 1
			respond({
				answers = {
					{type = mock.A, rdata = "22.22.22.22", ttl = 60},
				},
			})
		end
	end)
	-- First: SRV query which includes A glue in additional section
	local rr = dns.resolve("t22.mock.test", dns.SRV, 2000)
	testaux.assertneq(rr, nil, "Test 22.1: SRV should resolve")
	testaux.asserteq(rr[1].target, "t22-target.mock.test",
		"Test 22.2: SRV target correct")
	-- Now lookup the A record for the target - should be in cache from additional
	local ip = dns.lookup("t22-target.mock.test", dns.A, 2000)
	testaux.asserteq(ip, "22.22.22.22",
		"Test 22.3: Target A record from additional section")
	testaux.asserteq(a_query_count, 0,
		"Test 22.4: Server should NOT be queried for A (cached from additional)")
end)

-----------------------------------------------------------------
testaux.case("Test 23: EDNS0 OPT pseudo-record", function()
	local has_opt = false
	server:set_handler(function(query, respond)
		if query.name == "t23.mock.test" then
			-- Check if query has ARCOUNT >= 1 (OPT record present)
			if query.arcount >= 1 then
				has_opt = true
			end
			respond({
				answers = {
					{type = mock.A, rdata = "23.23.23.23", ttl = 10},
				},
			})
		end
	end)
	local ip = dns.lookup("t23.mock.test", dns.A, 2000)
	testaux.asserteq(ip, "23.23.23.23",
		"Test 23.1: Query with EDNS0 should resolve")
	testaux.asserteq(has_opt, true,
		"Test 23.2: Query should include OPT record (ARCOUNT >= 1)")
end)

-----------------------------------------------------------------
testaux.case("Test 24: CNAME-only after negative cache (stale neg)", function()
	-- Phase 1: NXDOMAIN + SOA with short TTL → negative cache
	local phase = 1
	server:set_handler(function(query, respond)
		if query.name:lower() == "t24.mock.test" and query.qtype == mock.A then
			if phase == 1 then
				respond({
					rcode = 3, -- NXDOMAIN
					answers = {},
					authority = {
						{type = mock.SOA, name = "mock.test",
						 rdata = {minimum = 1}, ttl = 1},
					},
				})
			else
				-- Phase 2: return CNAME only
				respond({
					answers = {
						{type = mock.CNAME, name = "t24.mock.test",
						 rdata = "t24-real.mock.test", ttl = 60},
					},
				})
			end
		elseif query.name:lower() == "t24-real.mock.test" and query.qtype == mock.A then
			respond({
				answers = {
					{type = mock.A, rdata = "24.24.24.24", ttl = 60},
				},
			})
		end
	end)
	-- Phase 1: should get nil (NXDOMAIN)
	local ip = dns.lookup("t24.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil, "Test 24.1: NXDOMAIN should return nil")
	-- Wait for negative cache TTL to expire (SOA MINIMUM=1s)
	time.sleep(1100)
	-- Phase 2: domain now returns CNAME
	phase = 2
	local ip2 = dns.lookup("t24.mock.test", dns.A, 2000)
	testaux.asserteq(ip2, "24.24.24.24",
		"Test 24.2: CNAME-only after neg cache should resolve")
end)

-----------------------------------------------------------------
testaux.case("Test 25: Search suffix case mismatch", function()
	server:set_handler(function(query, respond)
		if query.name:lower() == "t25host.mock.test" and query.qtype == mock.A then
			respond({
				answers = {
					{type = mock.A, rdata = "25.25.25.25", ttl = 10},
				},
			})
		end
	end)
	-- search suffix with uppercase letters
	dns.conf { nameservers = {"127.0.0.1:" .. PORT}, search = {"Mock.TEST"} }
	local ip = dns.lookup("t25host", dns.A, 2000)
	testaux.asserteq(ip, "25.25.25.25",
		"Test 25.1: Uppercase search suffix should resolve")
	dns.conf { nameservers = {"127.0.0.1:" .. PORT} }
end)

-----------------------------------------------------------------
testaux.case("Test 26: QDCOUNT != 1 rejected", function()
	server:set_handler(function(query, respond, respond_raw)
		if query.name == "t26.mock.test" and query.qtype == mock.A then
			-- Send bad response with QDCOUNT=2
			local question = query.raw:sub(query.question_start, query.question_end)
			local header = string.pack(">I2I2I2I2I2I2",
				query.id,
				0x8180, -- standard response
				2,      -- QDCOUNT=2 (invalid)
				1,      -- ANCOUNT=1
				0, 0)
			-- Duplicate question + a fake answer
			local answer_name = "\xc0\x0c" -- pointer to QNAME
			local answer_rr = string.pack(">I2I2I4I2",
				mock.A, 1, 300, 4) .. "\x63\x63\x63\x63" -- 99.99.99.99
			respond_raw(header .. question .. question .. answer_name .. answer_rr)
			-- Then send correct response
			task.fork(function()
				time.sleep(100)
				local correct = mock.build_response(query, {
					answers = {{type = mock.A, rdata = "26.26.26.26", ttl = 10}},
				})
				server.conn:sendto(correct, query.client_addr)
			end)
		end
	end)
	local ip = dns.lookup("t26.mock.test", dns.A, 2000)
	-- QDCOUNT=2 response should be rejected; correct one accepted
	testaux.assertneq(ip, "99.99.99.99",
		"Test 26.1: QDCOUNT=2 response data should not be accepted")
	testaux.asserteq(ip, "26.26.26.26",
		"Test 26.2: Should accept correct response after bad one")
end)

-----------------------------------------------------------------
testaux.case("Test 27: Multiple A records", function()
	server:set_handler(function(query, respond)
		if query.name == "t27.mock.test" and query.qtype == mock.A then
			respond({
				answers = {
					{type = mock.A, rdata = "127.0.0.2", ttl = 10},
					{type = mock.A, rdata = "127.0.0.1", ttl = 10},
				},
			})
		end
	end)
	local rr = dns.resolve("t27.mock.test", dns.A, 2000)
	testaux.assertneq(rr, nil, "Test 27.1: resolve should return results")
	testaux.asserteq(#rr, 2, "Test 27.2: Should have 2 A records")
	table.sort(rr)
	testaux.asserteq(rr[1], "127.0.0.1", "Test 27.3: First A record")
	testaux.asserteq(rr[2], "127.0.0.2", "Test 27.4: Second A record")
end)

-----------------------------------------------------------------
testaux.case("Test 28: Multiple AAAA records", function()
	server:set_handler(function(query, respond)
		if query.name == "t28.mock.test" and query.qtype == mock.AAAA then
			respond({
				answers = {
					{type = mock.AAAA, rdata = "0000:0000:0000:0000:0000:0000:0000:0002", ttl = 10},
					{type = mock.AAAA, rdata = "0000:0000:0000:0000:0000:0000:0000:0001", ttl = 10},
				},
			})
		end
	end)
	local rr = dns.resolve("t28.mock.test", dns.AAAA, 2000)
	testaux.assertneq(rr, nil, "Test 28.1: resolve should return results")
	testaux.asserteq(#rr, 2, "Test 28.2: Should have 2 AAAA records")
	table.sort(rr)
	testaux.asserteq(rr[1], "::1", "Test 28.3: First AAAA record (canonical)")
	testaux.asserteq(rr[2], "::2", "Test 28.4: Second AAAA record (canonical)")
end)

-----------------------------------------------------------------
testaux.case("Test 29: Failcount-based server selection", function()
	local PORT2 = 15358
	local PORT3 = 15359
	local server2 = mock.new(PORT2)
	local server3 = mock.new(PORT3)
	server2:start()
	server3:start()
	local server1_count = 0
	local server2_count = 0
	local server3_count = 0
	-- Server1: never responds (will accumulate failcount)
	server:set_handler(function(query, respond)
		if query.name:match("^t29") then
			server1_count = server1_count + 1
			-- no response → timeout
		end
	end)
	server2:set_handler(function(query, respond)
		if query.name:match("^t29") then
			server2_count = server2_count + 1
			respond({
				answers = {
					{type = mock.A, rdata = "29.29.29.29", ttl = 0},
				},
			})
		end
	end)
	server3:set_handler(function(query, respond)
		if query.name:match("^t29") then
			server3_count = server3_count + 1
			respond({
				answers = {
					{type = mock.A, rdata = "29.29.29.30", ttl = 0},
				},
			})
		end
	end)
	-- 3 servers: server1 will fail, server2 and server3 respond
	dns.conf {
		nameservers = {
			"127.0.0.1:" .. PORT,
			"127.0.0.1:" .. PORT2,
			"127.0.0.1:" .. PORT3,
		},
		timeout = 1, attempts = 1,
	}
	-- 29.1: First query goes to server1 (failcount=0), times out
	local ip = dns.lookup("t29a.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 29.1: First query to server1 should timeout")
	testaux.asserteq(server1_count, 1,
		"Test 29.2: Server1 should have received query")
	-- 29.3: After server1 failure, server2 (failcount=0) should be preferred
	local ip2 = dns.lookup("t29b.mock.test", dns.A, 2000)
	testaux.asserteq(ip2, "29.29.29.29",
		"Test 29.3: Should resolve via server2 after server1 failure")
	testaux.asserteq(server2_count, 1,
		"Test 29.4: Server2 should have received query")
	-- 29.5: Server2 succeeded so failcount=0, still preferred
	local ip3 = dns.lookup("t29c.mock.test", dns.A, 2000)
	testaux.asserteq(ip3, "29.29.29.29",
		"Test 29.5: Server2 should still be preferred (failcount=0)")
	testaux.asserteq(server3_count, 0,
		"Test 29.6: Server3 should not have been queried")
	server2:stop()
	server3:stop()
	dns.conf { nameservers = {"127.0.0.1:" .. PORT} }
end)

-----------------------------------------------------------------
testaux.case("Test 30: Failcount recovery", function()
	local PORT2 = 15358
	local server2 = mock.new(PORT2)
	server2:start()
	local server1_count = 0
	local server2_count = 0
	local server1_respond = true
	server:set_handler(function(query, respond)
		if query.name:match("^t30") then
			server1_count = server1_count + 1
			if server1_respond then
				respond({
					answers = {
						{type = mock.A, rdata = "30.0.0.1", ttl = 0},
					},
				})
			end
			-- else: no response → timeout
		end
	end)
	server2:set_handler(function(query, respond)
		if query.name:match("^t30") then
			server2_count = server2_count + 1
			respond({
				answers = {
					{type = mock.A, rdata = "30.0.0.2", ttl = 0},
				},
			})
		end
	end)
	dns.conf {
		nameservers = {"127.0.0.1:" .. PORT, "127.0.0.1:" .. PORT2},
		timeout = 1, attempts = 1,
	}
	-- Phase 1: server1 fails
	server1_respond = false
	local ip = dns.lookup("t30a.mock.test", dns.A, 2000)
	testaux.asserteq(ip, nil,
		"Test 30.1: Server1 should timeout")
	-- Phase 2: now server2 is preferred
	local ip2 = dns.lookup("t30b.mock.test", dns.A, 2000)
	testaux.asserteq(ip2, "30.0.0.2",
		"Test 30.2: Server2 should be preferred after server1 failure")
	-- Phase 3: server1 recovers — make it respond again
	-- To reset server1's failcount, we need it to handle a query successfully.
	-- But server2 is currently preferred (failcount=0). Make server2 fail so
	-- server1 (lower failcount) gets tried and succeeds.
	server1_respond = true
	server2:set_handler(function(query, respond)
		if query.name:match("^t30") then
			server2_count = server2_count + 1
			-- no response → timeout
		end
	end)
	local ip3 = dns.lookup("t30c.mock.test", dns.A, 2000)
	-- server2 times out (failcount was 0, now 1), server1 had failcount 1
	-- Next query: both have failcount>=1, server1 has failcount=1, server2 has failcount=1
	-- server1 is first in list with equal failcount, so it's picked
	testaux.asserteq(ip3, nil,
		"Test 30.3: Server2 should timeout")
	local ip4 = dns.lookup("t30d.mock.test", dns.A, 2000)
	testaux.asserteq(ip4, "30.0.0.1",
		"Test 30.4: Server1 should recover and be selected")
	-- After successful query, server1's failcount resets to 0
	server1_count = 0
	local ip5 = dns.lookup("t30e.mock.test", dns.A, 2000)
	testaux.asserteq(ip5, "30.0.0.1",
		"Test 30.5: Server1 should remain preferred after recovery")
	testaux.asserteq(server1_count, 1,
		"Test 30.6: Server1 should receive the query")
	server2:stop()
	dns.conf { nameservers = {"127.0.0.1:" .. PORT} }
end)

-----------------------------------------------------------------
testaux.case("Test 31: dns.isname()", function()
	testaux.asserteq(dns.isname("example.mock.test"), true,
		"Test 31.1: Hostname should return true")
	testaux.asserteq(dns.isname("127.0.0.1"), false,
		"Test 31.2: IPv4 address should return false")
	testaux.asserteq(dns.isname("::1"), false,
		"Test 31.3: IPv6 address should return false")
end)

-----------------------------------------------------------------
server:stop()
