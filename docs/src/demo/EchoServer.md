---
icon: laptop-code
category:
  - 示例
tag:
  - Echo服务器
---

# Echo服务器

```lua
local tcp = require "silly.net.tcp"
local listenfd = tcp.listen("127.0.0.1:8888", function(fd, addr)
	while true do
		local l = tcp.readline(fd, "\n")
		if not l then
				print("disconnected", fd)
				break
		end
		tcp.write(fd, l)
	end
end)
```

# 性能测试



