local env = require "silly.env"

print(env.get("daemon"))
print(env.get("listen.port1"))
print(env.get("listen.port2"))
print(env.get("listen.port3"))
print(env.set("daemon", "test"))
print(env.get("daemon"))

