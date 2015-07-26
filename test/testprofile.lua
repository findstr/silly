local profile = require("profile")

local start = profile.start();

local count = 3
for i = 1, 10000000 do
        cout = count + 1
end

local stop = profile.start()

print('--run:', stop - start, "ms--")

