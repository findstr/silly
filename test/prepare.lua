local LUA_VERSION = _VERSION:match("Lua (%d+.%d+)")

package.path = (
	"./.lua_modules/share/lua/" .. LUA_VERSION .. "/?.lua;" ..
	"./.lua_modules/share/lua/" .. LUA_VERSION .. "/?/init.lua;" ..
	package.path
)
package.cpath = (
	"./.lua_modules/lib/lua/" .. LUA_VERSION .. "/?.so;" ..
	package.cpath
)

local ok, _ = pcall(require, "luacov")
if ok then
	print("[luacov] Lua coverage collection enabled")
end

return true
