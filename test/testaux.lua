local silly = require "silly"
local hive = require "silly.hive"
local time = require "silly.time"
local json = require "silly.encoding.json"
local metrics = require "silly.metrics.c"
local c = require "test.aux.c"
local type = type
local pairs = pairs
local tostring = tostring
local format = string.format
local testaux = {}
local m = ""
local rand = math.random

local meta_str = "abcdefghijklmnopqrstuvwxyz"
local meta = {}
for i = 1, #meta_str do
	meta[#meta + 1] = meta_str:sub(i, i)
end

math.randomseed(time.now())

--inhierit testaux.c function
for k, v in pairs(c) do
	testaux[k] = v
end

local function escape(a)
	if type(a) == "string" then
		return a:gsub("([%c\x7f-\xff])", function(s)
			return string.format("\\x%02x", s:byte(1))
		end)
	elseif type(a) == "table" then
		local l = {}
		for k, v in pairs(a) do
			local t = type(v)
			if t == "function" then
				v = tostring(v)
			elseif t == "number" then
				v = string.format("%g", v)
			end
			l[#l + 1] = {k, v}
		end
		table.sort(l, function(a, b)
			return tostring(a[1]) < tostring(b[1])
		end)
		return json.encode(l)
	else
		return a
	end
end

local bee = hive.spawn [[
	package.cpath = package.cpath .. ";luaclib/?.so;luaclib/?.dll"
	local c = require "test.aux.c"
	return function(fd, len)
		return c.recv(fd, len)
	end
]]

function testaux.recv(fd, n)
	return hive.invoke(bee, fd, n)
end

function testaux.randomdata(sz)
	local tbl = {}
	for i = 1, sz do
		tbl[#tbl+1] = meta[rand(#meta)]
	end
	return table.concat(tbl, "")
end

function testaux.checksum(acc, str)
	for i = 1, #str do
		acc = acc + str:byte(i)
	end
	return acc
end

local function tostringx(a, len)
	a = tostring(a)
	if #a > len then
		a = a:sub(1, len) .. "..."
	end
	return a
end

function testaux.hextostr(arr)
	local buf = {}
	for i = 1, #arr do
		buf[i] = format("%02x", arr:byte(i))
	end
	return table.concat(buf, "")
end

function testaux.error(str)
	print(format('\27[31m%sFAIL\t"%s"\27[0m', m, str))
	print(debug.traceback(1))
	silly.exit(1)
end

function testaux.success(str)
	print(format('\27[32m%sSUCCESS\t"%s"\27[0m', m, str))
end

function testaux.asserteq(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 60)
	b = tostringx(bb, 60)
	if aa == bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t"%s" == "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t"%s" == "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		silly.exit(1)
	end
end

function testaux.assertneq(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa ~= bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t"%s" ~= "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t"%s" ~= "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		silly.exit(1)
	end
end

function testaux.assertlt(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa < bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t "%s" < "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t "%s" < "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		silly.exit(1)
	end
end

function testaux.assertle(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa <= bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t "%s" <= "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t"%s" <= "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		silly.exit(1)
	end
end

function testaux.assertgt(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa > bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t"%s" > "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t"%s" > "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		silly.exit(1)
	end
end

function testaux.module(name)
	if name == "" then
		m = ""
	else
		m = name .. ":"
	end
end

function testaux.asserteq_hex(actual, expected, message)
	local to_hex = function(s)
		return (s:gsub('.', function(c) return string.format('%02x', string.byte(c)) end))
	end
	testaux.asserteq(to_hex(actual), to_hex(expected), message)

end

function testaux.assert_error(fn, str)
	local ok, err = pcall(fn)
	if not ok then
		print(format('\27[32m%sSUCCESS\t"%s" check exception \t\27[0m', m, str))
	else
		print(format('\27[31m%sFAIL\t"%s" check exception \t\27[0m', m, str))
		print(debug.traceback(1))
		silly.exit(1)
	end
end

function testaux.hexdump(s)
	return (s:gsub('.', function(c) return string.format('%02X', string.byte(c)) end))
end

function testaux.netstat()
	local tcpclient, sent_bytes, received_bytes, operate_request, operate_processed = metrics.netstat()
	return {
		tcpclient = tcpclient,
		ctrlcount = operate_processed - operate_request,
	}
end

-- TLS Certificate constants (PEM format)
testaux.CERT_A = [[-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUPc2faaWEjGh1RklF9XPAgYS5WSMwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI1MTAwOTA5NDc1M1oXDTM1MTAw
NzA5NDc1M1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEApmUl+7J8zeWdOH6aiNwRSOcFePTxuAyYsAEewVtBCAEv
LVGxQtrsVvd6UosEd0aO/Qz3hvV32wYzI0ZzjGGfy0lCCx9YB05SyYY+KpDwe/os
Mf4RtBS/jN1dVX7TiRQ3KsngMFSXp2aC6IpI5ngF0PS/o2qbwkU19FCELE6G5WnA
fniUaf7XEwrhAkMAczJovqOu4BAhBColr7cQK7CQK6VNEhQBzM/N/hGmIniPbC7k
TjqyohWoLGPT+xQAe8WB39zbIHl+xEDoGAYaaI8I7TlcQWwCOIxdm+w67CQmC/Fy
GTX5fPoK96drushzwvAKphQrpQwT5MxTDvoE9xgbhQIDAQABo1MwUTAdBgNVHQ4E
FgQUsjX1LC+0rS4Ls5lcE8yg5P85LqQwHwYDVR0jBBgwFoAUsjX1LC+0rS4Ls5lc
E8yg5P85LqQwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEADqDJ
HQxRjFPSxIk5EMrxkqxE30LoWKJeW9vqublQU/qHfMo7dVTwfsAvFpTJfL7Zhhqw
l20ijbQVxPtDwPB8alQ/ScP5VRqC2032KTi9CqUqTj+y58oDxgjnm06vr5d8Xkmm
nR2xhUecGkzFYlDoXo1w8XttMUefyHS6HWLXvu94V7Y/8YB4lBCEnwFnhgkYB9CG
RsleiOiZDsaHhnNQsnM+Xl1UJVxJlMStl+Av2rCTAj/LMHniXQ+9QKI/7pNDUeCL
qSdxZephYkeRF8C/i9R5G/gAL40kUFz0sgyXuv/kss3rrxsshKKTRbxnRm1k/J73
9ZiztVOeqpcxFxmf7Q==
-----END CERTIFICATE-----
]]

testaux.KEY_A = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCmZSX7snzN5Z04
fpqI3BFI5wV49PG4DJiwAR7BW0EIAS8tUbFC2uxW93pSiwR3Ro79DPeG9XfbBjMj
RnOMYZ/LSUILH1gHTlLJhj4qkPB7+iwx/hG0FL+M3V1VftOJFDcqyeAwVJenZoLo
ikjmeAXQ9L+japvCRTX0UIQsToblacB+eJRp/tcTCuECQwBzMmi+o67gECEEKiWv
txArsJArpU0SFAHMz83+EaYieI9sLuROOrKiFagsY9P7FAB7xYHf3NsgeX7EQOgY
BhpojwjtOVxBbAI4jF2b7DrsJCYL8XIZNfl8+gr3p2u6yHPC8AqmFCulDBPkzFMO
+gT3GBuFAgMBAAECggEAD5uyVetWuKuetVNu5IKcHnYJNeDoIacQ1YWtYF7SeVE/
HyWoFojZnYjGUSLYLuYP+J20RFUXQpTQzDDKGvN3XUbIaqmshLbsnhm5EB4baM29
Qo0+FOHTW//RxvjIF/Ys/JcGMBJnTV0Yz35VO0Ur6n9i0I3qAW2jk4DP/SX6kl9T
4iJj2Y+69y0bHjesfO71nCUUH6Ym2CHJRd6A4tCeYQr3U/CXOWggpUuPTXFWptt7
uSJjbTQgwUF5H83ih1CUdto1G5LPBUXVD5x2XZshgwZsL1au9kH2l/83BAHKK8io
LQ8FekLN6FLD83mvEwFPyrVhfipbeUz3bKrgEzvOmwKBgQDUbrAgRYCLxxpmguiN
0aPV85xc+VPL+dh865QHhJ0pH/f3fah/U7van/ayfG45aIA+DI7qohGzf03xFnO4
O51RHcRhnjDbXWY5l0ZpOIpvHLLCm8gqIAkX9bt7UyE+PxRSNvUt3kVFT3ZYnYCx
Wb1kiV1oRAzTf1l0X0qamFPqdwKBgQDIhV8OWTBrsuC0U3hmvNB+DPEHnyPWBHvI
+HMflas5gJiZ+3KvrS3vBOXFB3qfTD1LQwUPqeqY0Q41Svvsq2IQAkKedJDdMuPU
RoKaV/Qln85nmibscNcwVGQNUKTeSCJQ43ktrWT01UinamsSEOYTceMqwW10LDaF
Ff1MbKNs4wKBgQDMEPiIR7vQipdF2oNjmPt1z+tpNOnWjE/20KcHAdGna9pcmQ2A
IwPWZMwrcXTBGS34bT/tDXtLnwNUkWjglgPtpFa+H6R3ViWZNUSiV3pEeqEOaW/D
Z7rUlW5gbd8FWLtAryKfyWFpz4e0YLj7pWVWas6cFqLrmO5p6BBWqfYSyQKBgHyp
rjcVa+0JAHobircUm+pB0XeTkIv1rZ98FtaEDjdpo3XXxa1CVVRMDy03QRzYISMx
P2xFjvwCvHqVa5nv0r9xKEmq3oUmpk3KqFecZsUdXQ074QcOADqjvLAqetVWsz7m
rOeg7SrpjonGt1o7904Pd9OU/Z9D/YEv8pIY2GFRAoGASEf3+igRFSECUxLh9LZC
scAxCHh9sz15swDD/rdtEqLKGcxlu74YKkBnyQ/yWA4d/enPnvdP98ThXdXnX0X4
v1HSCliKZXW8cusnBRD2IOyxuIUV/qiMfARylMvlLBccgJR8+olH9f/yF2EFWhoy
125zQzr/ESlTL+5IWeNf2sM=
-----END PRIVATE KEY-----
]]

testaux.CERT_B = [[-----BEGIN CERTIFICATE-----
MIIDCzCCAfOgAwIBAgIUNM6HmOKmFaJkmLlF4P0l/xzct70wDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKbG9jYWxob3N0MjAeFw0yNTEwMDkwOTQ3NDNaFw0zNTEw
MDcwOTQ3NDNaMBUxEzARBgNVBAMMCmxvY2FsaG9zdDIwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDBrp7hSCfkAacYHDhLdhw5QJGNaYABM197uh2l9DDB
+3PBXCDlE3jt2fcu+sxcApYQrxNsl7xjf9+N1cEaYQdzxMb4k4Do7Q0b7nDbFZVy
qFSZ8qPdGFf+kzYWsjNnQp4FWjRWxFrgLOXIBjSH6LvLkDvBez7D+CvB3dpm3Y7+
7daofyq7kcjM6efuYg0OemHz1sh/6ruKtMPgO8v47vcNRQXliScJRFGOeuv02Rxg
LK6LoB+PZitVYuYjJwO9WDnQTPRUYEF9VTu7AWVqkGPKZ9404m+SIyfOZqpQlHPW
gxxV0v7Hf26bmTTwq08Y7AxJQ9GcHjOuAlj2envzlzHHAgMBAAGjUzBRMB0GA1Ud
DgQWBBRo5n9FzjMGPciEl4w59X43Rjp7yjAfBgNVHSMEGDAWgBRo5n9FzjMGPciE
l4w59X43Rjp7yjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCx
AZGPtv8dDUqBBtsg4lyZ4fW6LGQgPnPy22YyBEEbcDcl52fQryz1+KqLH125PePF
/CYhXZzRvzm3MpqD8Tcn3GKH8OKzpu0rursFEnK+vfbzLxK65u04rTZXRa1iODSK
Z+/nk64HbrQGq+9RnMNr8qW0QjLRGxajMTU1Z4/87oGmRYwuViHNE5vs6LE+U30w
h22oN5ZhgpZ0hOCKhVHMrYe8lCHkdN14BktdoVDbyZZczhlW6D0WRerRYJcDmAOc
ae/yNoyHweiGsnfX6sK5xWWPwMhI9DyOzKfLTZlXszrygyC5Krt9QJGZyGvwIUIw
dzJJDoKUFQzV+u/yU4OO
-----END CERTIFICATE-----
]]

testaux.KEY_B = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDBrp7hSCfkAacY
HDhLdhw5QJGNaYABM197uh2l9DDB+3PBXCDlE3jt2fcu+sxcApYQrxNsl7xjf9+N
1cEaYQdzxMb4k4Do7Q0b7nDbFZVyqFSZ8qPdGFf+kzYWsjNnQp4FWjRWxFrgLOXI
BjSH6LvLkDvBez7D+CvB3dpm3Y7+7daofyq7kcjM6efuYg0OemHz1sh/6ruKtMPg
O8v47vcNRQXliScJRFGOeuv02RxgLK6LoB+PZitVYuYjJwO9WDnQTPRUYEF9VTu7
AWVqkGPKZ9404m+SIyfOZqpQlHPWgxxV0v7Hf26bmTTwq08Y7AxJQ9GcHjOuAlj2
envzlzHHAgMBAAECggEAOw5SlaCZwTUbzQc1xxShcHeWqgbEKBmRALn0Nljp0Qwp
9Ihx40d3tRaj/ygrzdZgCYBIrPDrWW9xK99EfRWe3xbeEIdxZBR7zct7j+HZ6tcW
zMYmXtEAa7hZYrw9Xjv60Oj7UoWWrAokmkQCGnrFYEF/ZvR8Y+a0+Oz7nifqZSJ5
GLCIQX8jIQdl0P8As1KqbSJA1ZIsB/RVKvYN9sOj4Y2GeHZJ7SAyI5NV0an59S5X
IduHPx9kU496AEXyd1c4Ps0Ucytk5bfU2KDvVp9y3JSU8Te0z8+bQWBkcORDehmB
1f5CI/DU1QzZl2LhisO+Nw8bud4bNWOvmky6Ruk0mQKBgQD/57rDEl4g/9l7rpfn
QG8lRLQLEJN+lSbj62t/bTGMb2EANCMmcrplI96tsKr8UI9FsA7kgyQypwIig+my
0X2lbhe2Z4IgBNxqdmJx87p2Uu5ZHWNjoSBIAWqdpP36joSeek0bLNvEDbwBUJZ2
U5rh20ALcsvYG27MYGkmsFZ4GwKBgQDBwP1gKoxc5MU2TCeK/nBRdAE229lTMoD1
uyYlTvUSTw9jBTxpxd+ZbjD4/Cw77DOm1ZA3nnkXRjCGIgoTbOOd2cFJjepWsspj
1N/TZ3pmgOxmuEB3DzoMxGSZ+8mpTfoccy1Wp/aHq+9vp3RXDV/pTT2HP1iEzfGB
G5qr1JyfxQKBgCN8fumOIn9w+zerfmUTClagsFbYdZuYE0yH2OBSxAw1Zb4hfL5Y
KoDb+IUdepiCk1uWjnohtWNQxXsDz+R8KHBIVAF3WRQXmHkq8Xvb0H+YAHVbHe0y
6scRazdxKccU/E79prOeBNurC+cixbqi3Vd0j+0Gfj35j+PHes1ippsBAoGAYo4A
VEJQU5AqoIvsMU9rYoNXesgpq6As6NHhfWjEUCPW989aA5ObQThDwOLEvVZQj7Ri
P2hkv+n8FL6L0YW54jk5kGiXorIfMNi/YZFpOWqq1TUz1Vvxcz0SzyC8W1pGtuH/
VezqAej7ShgrnXw4JTwc6AbYx/TZu4qHCpCDeuECgYEArkANYWWzmuUUgJ6Ozdk5
yqCwaMU2D/FgwCojunc+AorOVe8mG935NbQsCsk1CVYJAoKgYsr3gJNGQVD84pXz
iiGTFMMf2FOAZkUSzsbWOVyD02zaO8nPHzFI5/EUHRiI5v0ucxG2uEUCYFWQqs21
2THXCcOrfT8C487VGOFIGYw=
-----END PRIVATE KEY-----
]]

testaux.CERT_DEFAULT = [[-----BEGIN CERTIFICATE-----
MIIEHTCCAwWgAwIBAgIQLrTfDZi0TgOdQPledc1ZaDANBgkqhkiG9w0BAQsFADBe
MQswCQYDVQQGEwJDTjEOMAwGA1UEChMFTXlTU0wxKzApBgNVBAsTIk15U1NMIFRl
c3QgUlNBIC0gRm9yIHRlc3QgdXNlIG9ubHkxEjAQBgNVBAMTCU15U1NMLmNvbTAe
Fw0xOTExMjIwNjM4NDRaFw0yNDExMjAwNjM4NDRaMFQxCzAJBgNVBAYTAkNOMREw
DwYDVQQIEwhzaGFuZ2hhaTERMA8GA1UEBxMIc2hhbmdoYWkxCzAJBgNVBAoTAkNO
MRIwEAYDVQQDEwkxMjcuMC4wLjEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
AoIBAQDbmDkciBT37qKfmKKYFzVOXb+d9lhlwrC5Bnf/jDGtN7ZWrKJd+BLDpIsO
R2DYI8dBEWBtzuDt4PA4PzFa2KleR7m+1DW5m5FjkERoUMb/DGKSiskSahK3PqI7
euZ8XMoQpUwFIxpk+FZDTQEjXJyagYvIJ6fURplXsRKEEkzwYjKZ2BCNUDiG66TG
YXZ9uC39QuxEGQiOMz/ieGiaqLZD3ajJTSJ30aDQqmhj3jBU/t9Y0LL7JpDRfxYr
PJ8BoT8vFYfH1zmcu0JYOXRb9YuQTLu75Xwa9u5idg6ZWQk4hzuP+xTW2eDd/8Wp
UE2EZ9aFCQK6XWulcO5sf5+T39W7AgMBAAGjgeAwgd0wDgYDVR0PAQH/BAQDAgWg
MB0GA1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcDAjAfBgNVHSMEGDAWgBQogSYF
0TQaP8FzD7uTzxUcPwO/fzBjBggrBgEFBQcBAQRXMFUwIQYIKwYBBQUHMAGGFWh0
dHA6Ly9vY3NwLm15c3NsLmNvbTAwBggrBgEFBQcwAoYkaHR0cDovL2NhLm15c3Ns
LmNvbS9teXNzbHRlc3Ryc2EuY3J0MCYGA1UdEQQfMB2CCTEyNy4wLjAuMYEQZmlu
ZHN0ckBzaW5hLmNvbTANBgkqhkiG9w0BAQsFAAOCAQEAeleux51LBz7zRAWaje8e
cVxKbSqTSsUWi/ColPBI4MRQQUACUuvSCurkarkE/E8CWkXsN3xexFu+isLKaY7x
MjVUFyan10qy3V7CmGhE+iR1GMcgaMW+5Lblu29y60Oa4GJhu1+qL/Xt7yWVqJLh
SerEZg0K1rfVxWUEJsbdoPeGbBLioTfRm5IAT/ZJ/qnijajdLc28gSjLk2vHoQom
tMWH7KluIlW51aa4vhvx03TRh2iYd01EJbbT+kTW0flkyOs5i2etMitE2D/+EMBw
we7/U1e7rYPBddfIZA0N03rKNkudqyUlJZRB1fO+YOpAAlufVwuPAgu6fiQHn2Ol
dw==
-----END CERTIFICATE-----
]]

testaux.KEY_DEFAULT = [[-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA25g5HIgU9+6in5iimBc1Tl2/nfZYZcKwuQZ3/4wxrTe2Vqyi
XfgSw6SLDkdg2CPHQRFgbc7g7eDwOD8xWtipXke5vtQ1uZuRY5BEaFDG/wxikorJ
EmoStz6iO3rmfFzKEKVMBSMaZPhWQ00BI1ycmoGLyCen1EaZV7EShBJM8GIymdgQ
jVA4huukxmF2fbgt/ULsRBkIjjM/4nhomqi2Q92oyU0id9Gg0KpoY94wVP7fWNCy
+yaQ0X8WKzyfAaE/LxWHx9c5nLtCWDl0W/WLkEy7u+V8GvbuYnYOmVkJOIc7j/sU
1tng3f/FqVBNhGfWhQkCul1rpXDubH+fk9/VuwIDAQABAoIBAEfbDs0kRmA+yR4a
LxI/feTvzlTdGF3sEDHrSPbpJBQ/R74i7Vp8Y397Zzk76Bex1XCYRAqKiJWuZkyx
eO/2N62vILut6wqaOj/vJENSM1uf7N1w5ozNAuTNbP6zn5oQLtq1jCOeMfPaQzfw
ia/NjT0NqPTM7SEMHP9R5PIsntqFXCzKcueKIVgCgCPyfgZUq6I+PNy4BcmYWozE
4LHHApOV/uV7tkuxMzsVkXndeOKDYfew5t+QZVVS5TMxVsZViKO++b2x3mnplKKo
VFjtiilcw8/ODWyS5PoIlipTmmFkxbd4EEIxLWU8QeceMDGxdqtp74rtN1z9Drx9
PIPzOnECgYEA5Hugd26clhH9abqqMRcN8s2nF6Kg8CEYGP1DQINpZVY3xqLJucbw
x73vmygmKFRIN8BkmiCdpgbTxGMeOdcdfE6VfHR+1SbugJc58EF9kZxuSoLmxDzd
pQT5NuJIGwFGKb0SbAteSsK0JbqNwE8AIcM/Y69dHDfzwZ4EWtWwfpkCgYEA9gqP
gnZxJ+2uLyB0rAq50m9wrNr/VFhbYs7qSnmXk/A7SZ59cV1bh9veBcm9dz+oJRTo
gMzKomfrW6Qb10faecStrPCH/GpXArcK6pJrDAb1N4uzII1WcqVeYC+Q8KOiD4Rc
05mH70ZhzZC3E295J4aVDIkWju7Nk9UtxScMD3MCgYEAnk2lhXpG1ZdLS9kAGBkQ
Gf0w2yhbd2SGjLHUybsC6CpPZLnfKG9U3h+UBp1PqruSecY8LamRcLnkOXovNAX+
MOVFn0AbrFVYBBJDG1pUxPFsXQXLG4XMT4xdmxA2wzcjxMFyJRfPUd8K7+UMV4Sk
47+iiM+0pFuD8M8p10GdEmkCgYEArWG9xbr/fJqyf4VIkqAwWImthjIBcgedxqB3
XCoZVegZb4Sfc47NXIzlBYEn4eva6t60BWfLd+zxXy/jaq6418xwcwlBWu/5BvHE
YI7znpMcpJrujQbsn3fHbNK4Ocul/XdSDs8Hiuc3LqxHRwvr/Z2KVT4ZxnmkJwQ3
79HXXt8CgYAfQPbX6btTaAqOgevKRZGhdI1d71RjmP8giKeD5I1MjIu2H8CzYFe7
S5ydyV+nO5V1Vd8zlekfayMPJpqIBBD5kEDUM2TMfI2YOEnIxlJy5JKZNb3lLFY8
mUUZr4V3vliQKy5C0whB3QgiaboJnQS45YyddKWYI114RaF5iwzniw==
-----END RSA PRIVATE KEY-----
]]

return testaux


