---
title: silly.patch
icon: arrows-rotate
category:
  - API参考
tag:
  - 工具
  - 热更新
  - 运维
---

# silly.patch

模块热更新工具，支持运行时替换Lua函数和模块，无需重启服务器即可修复bug或更新功能。

## 模块导入

```lua validate
local patch = require "silly.patch"
```

## 核心概念

热更新的核心是保持函数的 **upvalue** 连续性：

- **Upvalue**: 函数闭包捕获的外部变量
- **问题**: 直接替换函数会丢失原有的upvalue状态
- **解决**: 通过debug库将新函数的upvalue连接到旧函数的upvalue

## API

### patch.new()
创建一个新的patch实例。

- **返回值**: `Patch` - patch对象
- **说明**: 每次热更新操作应该使用独立的patch实例

### patch:collectupval(f_or_t)
收集函数或模块的所有upvalue。

- **参数**:
  - `f_or_t`: `function|table` - 函数或模块表
- **返回值**: `table` - upvalue树
- **说明**:
  - 如果是函数，收集该函数及其内部所有嵌套函数的upvalue
  - 如果是表，收集表中所有函数的upvalue
  - 返回的树结构包含upvalue的名称、类型、值、索引等信息

### patch:join(f1, up1, f2, up2)
连接新旧函数的upvalue。

- **参数**:
  - `f1`: `function|table` - 旧函数或模块
  - `up1`: `table` - 旧函数的upvalue树（由 `collectupval` 返回）
  - `f2`: `function|table` - 新函数或模块
  - `up2`: `table` - 新函数的upvalue树
- **返回值**: `table` - 缺失的upvalue路径列表
- **说明**:
  - 将 `f1` 的upvalue连接到 `f2` 的upvalue
  - 只连接两者都存在的upvalue
  - 对于 `_ENV` upvalue，会自动设置为全局环境
  - 返回在 `f2` 中存在但 `f1` 中不存在的upvalue路径

## 使用示例

### 示例1：基本用法

```lua validate
local patch = require "silly.patch"

-- 创建patch实例
local P = patch.new()
print("Patch instance created")
```

::: tip 重要说明
patch模块用于高级热更新场景。由于其复杂性，建议在测试环境充分验证后再在生产环境使用。具体使用方法请参考 `test/testpatch.lua` 中的测试用例。
:::

### 示例2：简单模块热更新

```lua
-- 旧模块 mymodule.lua v1
local M = {}
local count = 0

function M.increment()
    count = count + 1
    return count
end

function M.get()
    return count
end

return M
```

```lua
-- 新模块 mymodule.lua v2（修复bug：增加步长）
local M = {}
local count = 0
local step = 2  -- 新增配置

function M.increment()
    count = count + step  -- 使用step
    return count
end

function M.get()
    return count
end

function M.set_step(n)  -- 新增函数
    step = n
end

return M
```

热更新脚本：

```lua
local patch = require "silly.patch"
local mymodule = require "mymodule"

-- 加载新版本
package.loaded["mymodule"] = nil
local mymodule_new = require "mymodule"
package.loaded["mymodule"] = mymodule  -- 恢复旧版本引用

-- 执行热更新
local P = patch.new()
local up1 = P:collectupval(mymodule)
local up2 = P:collectupval(mymodule_new)
local absent = P:join(mymodule_new, up2, mymodule, up1)  -- 参数：新函数, 新upval, 旧函数, 旧upval

-- 替换函数
for name, fn in pairs(mymodule_new) do
    mymodule[name] = fn
end

-- 检查缺失的upvalue
if #absent > 0 then
    print("Warning: missing upvalues:", table.concat(absent, ", "))
end
```

### 示例3：通过console注入热更新

可以通过 `silly.console` 的 `INJECT` 命令执行热更新：

创建热更新脚本 `/tmp/hotfix.lua`：

```lua
-- /tmp/hotfix.lua
local patch = require "silly.patch"
local mymodule = require "mymodule"

-- 加载新版本（假设已经部署到服务器）
package.loaded["mymodule"] = nil
local mymodule_new = require "mymodule"
package.loaded["mymodule"] = mymodule  -- 恢复旧版本引用

-- 热更新
local P = patch.new()
local up1 = P:collectupval(mymodule)
local up2 = P:collectupval(mymodule_new)
local absent = P:join(mymodule_new, up2, mymodule, up1)

-- 替换函数
for name, fn in pairs(mymodule_new) do
    mymodule[name] = fn
end

print("Hotfix applied successfully")
if #absent > 0 then
    print("Warning: absent upvalues:", table.concat(absent, ", "))
end
```

在console中执行：

```
console> inject /tmp/hotfix.lua
Hotfix applied successfully
Inject file:/tmp/hotfix.lua Success
```

## Upvalue树结构

`collectupval` 返回的upvalue树结构：

```lua
{
    ["函数名"] = {
        val = function,      -- 函数本身
        upvals = {           -- upvalue表
            ["upvalue名"] = {
                idx = integer,     -- upvalue索引
                utype = "string",  -- upvalue类型
                val = any,         -- upvalue值
                upid = lightuserdata, -- upvalue ID（用于比较）
                upvals = table,    -- 如果是函数，递归的upvalue
            }
        }
    }
}
```

## 注意事项

::: warning 兼容性要求
新旧模块的upvalue结构应该尽可能相似。如果新模块删除了旧模块的upvalue，可能导致运行时错误。
:::

::: warning 定时器和协程
如果upvalue被定时器或协程引用，需要特别小心。可能需要手动处理这些异步上下文中的函数引用。
:::

::: danger 状态一致性
热更新不会自动迁移数据结构。如果新版本修改了数据结构（如表的字段），需要手动编写迁移代码。
:::

::: tip 测试建议
热更新前应该在测试环境充分测试，确保upvalue连接正确。可以使用返回的 `absent` 列表检查是否有upvalue缺失。
:::

## 限制

1. **C函数**: 无法热更新C函数
2. **元表**: 不会自动更新元表，需要手动处理
3. **全局引用**: 如果其他模块持有旧函数的引用，不会自动更新
4. **协程**: 已经在执行的协程栈帧不会更新
5. **循环引用**: 复杂的循环引用可能需要手动处理

## 最佳实践

### 1. 使用模块表

将模块定义为表，而不是独立函数，便于批量替换：

```lua
-- 好的做法
local M = {}
function M.foo() ... end
function M.bar() ... end
return M

-- 不好的做法
local function foo() ... end
local function bar() ... end
return foo
```

### 2. 保持upvalue结构

新版本应该保持旧版本的upvalue结构：

```lua
-- 旧版本
local config = {timeout = 1000}
function M.get_timeout()
    return config.timeout
end

-- 好的新版本（保持config）
local config = {timeout = 2000, retry = 3}  -- 可以添加新字段
function M.get_timeout()
    return config.timeout
end

-- 不好的新版本（删除config）
function M.get_timeout()
    return 2000  -- 硬编码，失去了灵活性
end
```

### 3. 检查absent列表

```lua
local absent = P:join(M2, up2, M1, up1)  -- 新模块, 新upval, 旧模块, 旧upval
if #absent > 0 then
    print("Warning: missing upvalues:")
    for _, path in ipairs(absent) do
        print("  ", path)
    end
    -- 决定是否继续
end
```

### 4. 记录热更新日志

```lua
local logger = require "silly.logger"
logger.info("Applying hotfix for mymodule")
-- ... 执行热更新 ...
logger.info("Hotfix applied successfully")
```

### 5. 版本控制

```lua
-- 在模块中添加版本号
local M = {
    VERSION = "1.2.3"
}

-- 热更新时检查版本
if mymodule.VERSION ~= "1.2.2" then
    error("Version mismatch, expected 1.2.2, got " .. mymodule.VERSION)
end
```

## 实现原理

热更新依赖于Lua的debug库：

- `debug.getupvalue()`: 获取函数的upvalue
- `debug.setupvalue()`: 设置函数的upvalue
- `debug.upvalueid()`: 获取upvalue的唯一标识
- `debug.upvaluejoin()`: 使两个函数共享同一个upvalue

基本流程：

1. 收集旧函数的所有upvalue（包括嵌套函数）
2. 收集新函数的所有upvalue
3. 遍历新函数的upvalue，在旧函数中查找同名upvalue
4. 使用 `upvaluejoin` 将新函数的upvalue连接到旧函数的upvalue
5. 用新函数替换旧函数的引用

## 参见

- [silly.console](./console.md) - 控制台（INJECT命令）
- [Lua Debug Library](https://www.lua.org/manual/5.4/manual.html#6.10) - Lua调试库文档
- [Lua Closures](https://www.lua.org/pil/6.1.html) - Lua闭包和upvalue
