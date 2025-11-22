---
title: 热更新操作指南
icon: fire
order: 3
category:
  - 操作指南
tag:
  - 热更新
  - 运维
  - 最佳实践
---

# 热更新操作指南

本指南将教你如何在 Silly 框架中实现零停机的代码热更新，让你能够在不重启服务器的情况下修复 bug、更新功能和调整配置。

## 简介

### 什么是热更新

热更新（Hot Reload）是指在程序运行过程中动态替换代码，而无需重启进程。这对于需要 7×24 小时运行的服务器应用尤为重要。

### 优势

- **零停机时间**：无需重启服务，用户无感知
- **快速修复**：紧急 bug 可以立即修复上线
- **降低风险**：避免重启过程中的状态丢失
- **提高效率**：开发调试时可以快速验证代码修改

### 适用场景

热更新适合用于：

- **Bug 修复**：修复业务逻辑错误
- **功能更新**：添加新功能或优化现有功能
- **参数调整**：修改配置参数、阈值等
- **路由更新**：更新 HTTP 路由处理器
- **算法优化**：优化性能关键代码

### 不适合热更新的场景

以下情况不建议使用热更新：

- **核心框架代码**：如事件循环、消息系统等底层代码
- **数据结构变更**：需要修改持久化数据的结构
- **协议变更**：需要修改网络协议格式
- **依赖升级**：需要更新 C 扩展模块或第三方库
- **大规模重构**：涉及多个模块的架构调整

## 基础概念

### Upvalue 和闭包

热更新的核心是理解 Lua 的闭包机制：

```lua
-- 外部变量 config 被函数 get_timeout 捕获，成为 upvalue
local config = {timeout = 1000}

function get_timeout()
    return config.timeout  -- config 是 get_timeout 的 upvalue
end
```

当函数引用外部局部变量时，这个变量就成为函数的 **upvalue**（上值）。热更新时必须保持新旧函数的 upvalue 连续性，否则会丢失运行时状态。

### Upvalue 连续性

直接替换函数会导致 upvalue 丢失：

```lua
-- 旧代码
local count = 100  -- 当前值：100
function increment()
    count = count + 1
    return count
end

-- 错误的热更新方式
function increment()  -- 新函数的 count 是全新的变量
    count = count + 2  -- count 从初始值开始，而不是 100
    return count
end
-- 结果：count 的值丢失了
```

正确的热更新需要将新函数的 upvalue 连接到旧函数的 upvalue：

```lua
-- 使用 silly.patch 保持 upvalue 连续性
local patch = require "silly.patch"
local P = patch.new()

-- 收集新旧函数的 upvalue
local up_old = P:collectupval(old_module)
local up_new = P:collectupval(new_module)

-- 连接 upvalue（新函数使用旧函数的 upvalue）
P:join(up_new, up_old)

-- 替换函数引用
old_module.increment = new_module.increment
-- 结果：新函数继承了旧函数的 count 值（100）
```

## 使用 silly.patch

### 导入模块

```lua
local patch = require "silly.patch"
```

### 基本流程

热更新的标准流程包括 5 个步骤：

```lua
-- 1. 创建 patch 实例
local P = patch.new()

-- 2. 获取旧模块引用
local old_module = require "mymodule"

-- 3. 加载新模块（临时加载，不影响 package.loaded）
package.loaded["mymodule"] = nil
local new_module = require "mymodule"
package.loaded["mymodule"] = old_module  -- 恢复旧模块引用

-- 4. 收集并连接 upvalue
local up_old = P:collectupval(old_module)
local up_new = P:collectupval(new_module)
local absent = P:join(up_new, up_old)  -- 新 -> 旧

-- 5. 替换函数引用
for name, fn in pairs(new_module) do
    if type(fn) == "function" then
        old_module[name] = fn
    end
end

-- 检查是否有缺失的 upvalue
if #absent > 0 then
    print("Warning: new module has upvalues not in old module:")
    for _, path in ipairs(absent) do
        print("  " .. path)
    end
end
```

### API 说明

#### patch.new()

创建一个新的 patch 实例。每次热更新操作应使用独立的实例。

```lua
local P = patch.new()
```

#### P:collectupval(module)

收集模块中所有函数的 upvalue，返回 upvalue 树结构。

```lua
local up = P:collectupval(mymodule)
-- up 是一个树状结构，包含所有函数及其 upvalue 信息
```

#### P:join(up_new, up_old)

将新函数的 upvalue 连接到旧函数的 upvalue，保持状态连续性。

```lua
local absent = P:join(up_new, up_old)
-- absent 是一个数组，包含新模块中存在但旧模块中不存在的 upvalue 路径
```

**注意顺序**：第一个参数是新模块的 upvalue，第二个参数是旧模块的 upvalue。

## 完整示例

### 示例 1：热更新 HTTP 路由

假设你有一个 HTTP 服务，需要修改某个路由的处理逻辑。

**旧版本（route.lua v1）：**

```lua
local M = {}
local access_count = 0

function M.handle_request(req, res)
    access_count = access_count + 1
    res:status(200)
    res:send("Hello, visitor #" .. access_count)
end

function M.get_stats()
    return {total = access_count}
end

return M
```

**新版本（route.lua v2）：**

```lua
local M = {}
local access_count = 0
local error_count = 0  -- 新增错误计数

function M.handle_request(req, res)
    access_count = access_count + 1

    -- 新增错误处理逻辑
    if not req.params.name then
        error_count = error_count + 1
        res:status(400)
        res:send("Error: name is required")
        return
    end

    res:status(200)
    res:send("Hello, " .. req.params.name .. " (visitor #" .. access_count .. ")")
end

function M.get_stats()
    return {
        total = access_count,
        errors = error_count  -- 新增字段
    }
end

return M
```

**热更新脚本（hotfix_route.lua）：**

```lua
local patch = require "silly.patch"
local logger = require "silly.logger"

-- 获取旧模块
local route = require "route"

-- 记录热更新前的状态
local old_stats = route.get_stats()
logger.info("Before hotfix - Stats:", old_stats)

-- 加载新模块
package.loaded["route"] = nil
local route_new = require "route"
package.loaded["route"] = route  -- 恢复旧引用

-- 执行热更新
local P = patch.new()
local up_old = P:collectupval(route)
local up_new = P:collectupval(route_new)
local absent = P:join(up_new, up_old)

-- 替换函数
for name, fn in pairs(route_new) do
    if type(fn) == "function" then
        route[name] = fn
    end
end

-- 检查结果
if #absent > 0 then
    logger.warn("New upvalues detected:", table.concat(absent, ", "))
    -- error_count 是新增的 upvalue，需要手动初始化
    -- 由于 join 会创建新的 upvalue，默认值为 0，通常不需要额外处理
end

-- 验证状态保持
local new_stats = route.get_stats()
logger.info("After hotfix - Stats:", new_stats)

logger.info("Hotfix applied successfully")
```

### 示例 2：热更新业务逻辑模块

**旧版本（game.lua v1）：**

```lua
local M = {}
local player_data = {}

function M.add_player(id, name)
    player_data[id] = {
        name = name,
        score = 0
    }
end

function M.add_score(id, points)
    if player_data[id] then
        player_data[id].score = player_data[id].score + points
    end
end

function M.get_player(id)
    return player_data[id]
end

return M
```

**新版本（game.lua v2）：**

```lua
local M = {}
local player_data = {}

function M.add_player(id, name)
    player_data[id] = {
        name = name,
        score = 0,
        level = 1,  -- 新增等级系统
        exp = 0     -- 新增经验值
    }
end

function M.add_score(id, points)
    if player_data[id] then
        player_data[id].score = player_data[id].score + points

        -- 新增：获得经验值
        local exp = math.floor(points / 10)
        M.add_exp(id, exp)
    end
end

-- 新增函数
function M.add_exp(id, exp)
    local player = player_data[id]
    if not player then
        return
    end

    player.exp = player.exp + exp

    -- 升级逻辑
    while player.exp >= player.level * 100 do
        player.exp = player.exp - player.level * 100
        player.level = player.level + 1
    end
end

function M.get_player(id)
    return player_data[id]
end

return M
```

**热更新脚本（hotfix_game.lua）：**

```lua
local patch = require "silly.patch"
local logger = require "silly.logger"

local game = require "game"

-- 加载新版本
package.loaded["game"] = nil
local game_new = require "game"
package.loaded["game"] = game

-- 执行热更新
local P = patch.new()
local up_old = P:collectupval(game)
local up_new = P:collectupval(game_new)
local absent = P:join(up_new, up_old)

-- 替换函数
for name, fn in pairs(game_new) do
    if type(fn) == "function" then
        game[name] = fn
    end
end

-- 数据迁移：为现有玩家添加新字段
-- 注意：这里直接操作 upvalue 中的 player_data
local player_count = 0
for id, player in pairs(up_old.add_player.upvals.player_data.val) do
    if not player.level then
        player.level = 1
        player.exp = 0
        player_count = player_count + 1
    end
end

logger.info("Migrated " .. player_count .. " existing players")
logger.info("Hotfix applied successfully")
```

### 示例 3：热更新配置文件

**旧版本（config.lua v1）：**

```lua
local M = {}

local settings = {
    max_connections = 1000,
    timeout = 30,
    log_level = "INFO"
}

function M.get(key)
    return settings[key]
end

function M.set(key, value)
    settings[key] = value
end

function M.get_all()
    return settings
end

return M
```

**新版本（config.lua v2）：**

```lua
local M = {}

local settings = {
    max_connections = 1000,
    timeout = 30,
    log_level = "INFO",
    enable_cache = true,      -- 新增
    cache_ttl = 300          -- 新增
}

-- 新增：配置验证
local validators = {
    max_connections = function(v)
        return type(v) == "number" and v > 0 and v <= 10000
    end,
    timeout = function(v)
        return type(v) == "number" and v > 0
    end,
    log_level = function(v)
        local valid = {DEBUG = true, INFO = true, WARN = true, ERROR = true}
        return valid[v] ~= nil
    end
}

function M.get(key)
    return settings[key]
end

function M.set(key, value)
    -- 新增：配置验证
    if validators[key] and not validators[key](value) then
        error("Invalid value for " .. key)
    end
    settings[key] = value
end

function M.get_all()
    return settings
end

return M
```

**热更新脚本（hotfix_config.lua）：**

```lua
local patch = require "silly.patch"
local logger = require "silly.logger"

local config = require "config"

-- 保存当前配置值
local old_settings = config.get_all()

-- 加载新版本
package.loaded["config"] = nil
local config_new = require "config"
package.loaded["config"] = config

-- 执行热更新
local P = patch.new()
local up_old = P:collectupval(config)
local up_new = P:collectupval(config_new)
local absent = P:join(up_new, up_old)

-- 特殊处理：合并新增的配置项
local old_settings_uv = up_old.get.upvals.settings.val
local new_settings_uv = up_new.get.upvals.settings.val

for key, value in pairs(new_settings_uv) do
    if old_settings_uv[key] == nil then
        old_settings_uv[key] = value
        logger.info("Added new config: " .. key .. " = " .. tostring(value))
    end
end

-- 替换函数（新的 set 函数包含验证逻辑）
for name, fn in pairs(config_new) do
    if type(fn) == "function" then
        config[name] = fn
    end
end

logger.info("Config hotfix applied successfully")
```

## 最佳实践

### 1. 模块组织建议

#### 使用模块表而非独立函数

```lua
-- ✅ 推荐：使用模块表
local M = {}

function M.foo()
    -- ...
end

function M.bar()
    -- ...
end

return M
```

```lua
-- ❌ 不推荐：独立函数
local function foo()
    -- ...
end

return foo  -- 难以热更新多个函数
```

#### 保持 upvalue 结构稳定

```lua
-- ✅ 推荐：保持 upvalue 结构
-- 旧版本
local config = {timeout = 1000}
function M.get_timeout()
    return config.timeout
end

-- 新版本（添加新字段，保留原有结构）
local config = {timeout = 2000, retry = 3}
function M.get_timeout()
    return config.timeout
end
```

```lua
-- ❌ 不推荐：删除 upvalue
-- 旧版本
local config = {timeout = 1000}
function M.get_timeout()
    return config.timeout
end

-- 新版本（删除了 config upvalue）
function M.get_timeout()
    return 2000  -- 硬编码，失去灵活性
end
```

### 2. 避免热更新的模块

以下类型的模块不建议热更新：

```lua
-- ❌ 核心事件循环
local silly = require "silly"

-- ❌ 底层网络模块
local tcp = require "silly.net.tcp"

-- ❌ 带有复杂状态的模块
local M = {}
local state_machine = create_complex_state()  -- 状态机难以迁移

-- ✅ 业务逻辑模块（适合热更新）
local M = {}
function M.handle_user_request(req)
    -- 纯业务逻辑，容易热更新
end
```

### 3. 版本管理

在模块中添加版本信息，便于跟踪和验证：

```lua
local M = {
    VERSION = "1.2.3",
    BUILD_TIME = "2025-10-14T12:00:00Z"
}

-- 业务逻辑...

return M
```

热更新时检查版本：

```lua
local expected_version = "1.2.2"
if mymodule.VERSION ~= expected_version then
    error(string.format(
        "Version mismatch: expected %s, got %s",
        expected_version,
        mymodule.VERSION
    ))
end

-- 执行热更新...

-- 更新后验证
assert(mymodule.VERSION == "1.2.3", "Hotfix failed: version not updated")
```

### 4. 回滚机制

准备回滚方案，以防热更新失败：

```lua
local patch = require "silly.patch"
local logger = require "silly.logger"

-- 备份旧版本
local backup = {}
for name, fn in pairs(mymodule) do
    backup[name] = fn
end

-- 尝试热更新
local success, err = pcall(function()
    -- 加载新版本
    package.loaded["mymodule"] = nil
    local mymodule_new = require "mymodule"
    package.loaded["mymodule"] = mymodule

    -- 执行热更新
    local P = patch.new()
    local up_old = P:collectupval(mymodule)
    local up_new = P:collectupval(mymodule_new)
    local absent = P:join(up_new, up_old)

    -- 检查缺失的 upvalue
    if #absent > 3 then  -- 假设最多允许 3 个新 upvalue
        error("Too many missing upvalues: " .. table.concat(absent, ", "))
    end

    -- 替换函数
    for name, fn in pairs(mymodule_new) do
        if type(fn) == "function" then
            mymodule[name] = fn
        end
    end
end)

if not success then
    logger.error("Hotfix failed:", err)
    logger.info("Rolling back...")

    -- 回滚到旧版本
    for name, fn in pairs(backup) do
        mymodule[name] = fn
    end

    logger.info("Rollback completed")
else
    logger.info("Hotfix applied successfully")
end
```

### 5. 记录热更新日志

```lua
local logger = require "silly.logger"
local time = require "silly.time"

local function log_hotfix(module_name, version_old, version_new, success, error_msg)
    local log_entry = {
        timestamp = time.now(),
        module = module_name,
        version_old = version_old,
        version_new = version_new,
        success = success,
        error = error_msg
    }

    if success then
        logger.info("Hotfix applied:", log_entry)
    else
        logger.error("Hotfix failed:", log_entry)
    end

    -- 可选：写入数据库或文件
end

-- 使用示例
local old_version = mymodule.VERSION
-- 执行热更新...
local success, err = pcall(apply_hotfix)
local new_version = mymodule.VERSION

log_hotfix("mymodule", old_version, new_version, success, err)
```

### 6. 处理异步上下文

如果模块函数被定时器或协程引用，需要特别处理：

```lua
-- 问题示例：定时器持有旧函数引用
local M = {}
local count = 0

function M.timer_func()
    count = count + 1
    print("Count:", count)
end

-- 启动定时器
local time = require "silly.time"
local function repeat_call(ms, func)
    local function loop()
        func()
        time.after(ms, loop)
    end
    loop()
end
repeat_call(1000, M.timer_func)  -- 定时器持有 timer_func 的引用
```

解决方案 1：使用间接调用

```lua
local M = {}
local count = 0
local timer_func  -- 前向声明

function timer_func()
    count = count + 1
    print("Count:", count)
end

-- 使用包装函数
function M.timer_wrapper()
    timer_func()  -- 通过 upvalue 间接调用
end

M.timer_func = timer_func

-- 启动定时器
repeat_call(1000, M.timer_wrapper)

-- 热更新时，timer_func 是 timer_wrapper 的 upvalue
-- 通过 patch 可以正确更新
```

解决方案 2：重启定时器

```lua
-- 停止旧定时器
if M.timer_handle then
    time.cancel(M.timer_handle)
end

-- 执行热更新...

-- 启动新定时器
M.timer_handle = repeat_call(1000, M.timer_func)
```

### 7. 测试热更新

在生产环境使用前，务必在测试环境充分测试：

```lua
-- test_hotfix.lua
local patch = require "silly.patch"
local testaux = require "test.testaux"

-- 加载旧版本
local M1 = require "mymodule"

-- 执行一些操作，建立状态
M1.add_data("key1", "value1")
M1.add_data("key2", "value2")
assert(M1.count() == 2, "Initial state")

-- 执行热更新
package.loaded["mymodule"] = nil
local M2 = require "mymodule"
package.loaded["mymodule"] = M1

local P = patch.new()
local up1 = P:collectupval(M1)
local up2 = P:collectupval(M2)
P:join(up2, up1)

for k, v in pairs(M2) do
    if type(v) == "function" then
        M1[k] = v
    end
end

-- 验证状态保持
assert(M1.count() == 2, "State preserved after hotfix")
assert(M1.get_data("key1") == "value1", "Data preserved")

-- 测试新功能
M1.new_function()
assert(M1.count() == 3, "New function works")

print("Hotfix test passed")
```

## 故障排除

### 常见错误 1：upvalue 丢失

**症状**：

```
attempt to index a nil value (upvalue 'config')
```

**原因**：新函数的 upvalue 没有正确连接到旧函数的 upvalue。

**解决方法**：

```lua
-- 检查 absent 列表
local absent = P:join(up_new, up_old)
if #absent > 0 then
    print("Missing upvalues:", table.concat(absent, ", "))
    -- 手动处理缺失的 upvalue
end
```

### 常见错误 2：参数顺序错误

**症状**：热更新后，模块状态被重置为初始值。

**原因**：`P:join()` 的参数顺序错误。

**解决方法**：

```lua
-- ❌ 错误：顺序反了
P:join(up_old, up_new)  -- 会用新的 upvalue 覆盖旧的

-- ✅ 正确：新 -> 旧
P:join(up_new, up_old)  -- 新函数使用旧的 upvalue
```

### 常见错误 3：全局变量污染

**症状**：热更新后出现意外的全局变量。

**原因**：新模块中使用了全局变量。

**解决方法**：

```lua
-- 使用独立的环境加载新模块
local ENV = setmetatable({}, {__index = _ENV})
local new_module = loadfile("mymodule.lua", "bt", ENV)()

-- 热更新后，将需要的全局变量合并到 _ENV
for k, v in pairs(ENV) do
    if not _ENV[k] or type(v) == "function" then
        _ENV[k] = v
    end
end
```

### 常见错误 4：循环引用问题

**症状**：热更新后出现栈溢出或死循环。

**原因**：模块之间的循环引用没有正确处理。

**解决方法**：

```lua
-- 先更新所有模块，再连接 upvalue
local modules = {"module_a", "module_b", "module_c"}
local old_modules = {}
local new_modules = {}

-- 1. 加载所有新模块
for _, name in ipairs(modules) do
    old_modules[name] = require(name)
    package.loaded[name] = nil
    new_modules[name] = require(name)
    package.loaded[name] = old_modules[name]
end

-- 2. 统一执行热更新
for _, name in ipairs(modules) do
    local P = patch.new()
    local up_old = P:collectupval(old_modules[name])
    local up_new = P:collectupval(new_modules[name])
    P:join(up_new, up_old)

    for k, v in pairs(new_modules[name]) do
        if type(v) == "function" then
            old_modules[name][k] = v
        end
    end
end
```

### 调试技巧

#### 1. 打印 upvalue 树结构

```lua
local function print_upval_tree(up, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)

    for name, info in pairs(up) do
        if type(info) == "table" and info.upvals then
            print(prefix .. name .. ":")
            for uname, uinfo in pairs(info.upvals) do
                print(prefix .. "  [" .. uinfo.idx .. "] " .. uname ..
                      " (" .. uinfo.utype .. ")")
            end
            print_upval_tree(info.upvals, indent + 1)
        end
    end
end

-- 使用
local up = P:collectupval(mymodule)
print_upval_tree(up)
```

#### 2. 比较新旧 upvalue

```lua
local function compare_upvals(up_old, up_new)
    local old_keys = {}
    local new_keys = {}

    for name, info in pairs(up_old) do
        if info.upvals then
            for uname in pairs(info.upvals) do
                old_keys[name .. "." .. uname] = true
            end
        end
    end

    for name, info in pairs(up_new) do
        if info.upvals then
            for uname in pairs(info.upvals) do
                local key = name .. "." .. uname
                new_keys[key] = true
                if not old_keys[key] then
                    print("+ New upvalue: " .. key)
                end
            end
        end
    end

    for key in pairs(old_keys) do
        if not new_keys[key] then
            print("- Removed upvalue: " .. key)
        end
    end
end

-- 使用
compare_upvals(up_old, up_new)
```

#### 3. 验证热更新结果

```lua
local function verify_hotfix(old_module, new_module)
    -- 检查函数是否正确替换
    for name, fn in pairs(new_module) do
        if type(fn) == "function" then
            if old_module[name] ~= fn then
                print("Warning: " .. name .. " not replaced")
            end
        end
    end

    -- 检查版本号
    if old_module.VERSION and new_module.VERSION then
        if old_module.VERSION == new_module.VERSION then
            print("Warning: VERSION not updated")
        else
            print("Version updated: " .. old_module.VERSION ..
                  " -> " .. new_module.VERSION)
        end
    end
end

-- 使用
verify_hotfix(old_module, new_module)
```

## 生产环境实践

### 通过 console 执行热更新

Silly 框架支持通过 console 动态注入代码，这是生产环境最常用的热更新方式。

**1. 准备热更新脚本**

将热更新脚本保存到服务器（例如 `/tmp/hotfix_20251014.lua`）：

```lua
-- /tmp/hotfix_20251014.lua
local patch = require "silly.patch"
local logger = require "silly.logger"

logger.info("Starting hotfix 20251014...")

-- 执行热更新
local mymodule = require "mymodule"
package.loaded["mymodule"] = nil
local mymodule_new = require "mymodule"
package.loaded["mymodule"] = mymodule

local P = patch.new()
local up_old = P:collectupval(mymodule)
local up_new = P:collectupval(mymodule_new)
local absent = P:join(up_new, up_old)

for name, fn in pairs(mymodule_new) do
    if type(fn) == "function" then
        mymodule[name] = fn
    end
end

logger.info("Hotfix 20251014 completed successfully")

if #absent > 0 then
    logger.warn("New upvalues:", table.concat(absent, ", "))
end
```

**2. 连接 console 并执行**

```bash
# 连接到 console（假设 console 监听在 127.0.0.1:2345）
telnet 127.0.0.1 2345

# 或使用 nc
nc 127.0.0.1 2345
```

在 console 中执行：

```
console> inject /tmp/hotfix_20251014.lua
[INFO] Starting hotfix 20251014...
[INFO] Hotfix 20251014 completed successfully
Inject file:/tmp/hotfix_20251014.lua Success
```

### 批量热更新

如果需要更新多个服务器：

```bash
#!/bin/bash
# batch_hotfix.sh

SERVERS="server1:2345 server2:2345 server3:2345"
HOTFIX_SCRIPT="/tmp/hotfix_20251014.lua"

for server in $SERVERS; do
    echo "Applying hotfix to $server..."
    echo "inject $HOTFIX_SCRIPT" | nc -w 3 ${server/:/ }

    if [ $? -eq 0 ]; then
        echo "✓ $server hotfix completed"
    else
        echo "✗ $server hotfix failed"
    fi
done
```

## 参见

- [silly.patch API 参考](/reference/patch.md) - 详细的 API 文档
- [silly.console](/reference/console.md) - 控制台使用指南
- [Lua Debug Library](https://www.lua.org/manual/5.4/manual.html#6.10) - Lua 调试库文档
