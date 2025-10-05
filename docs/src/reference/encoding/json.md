---
title: json
icon: file-code
category:
  - API参考
tag:
  - 编码
  - JSON
  - 序列化
---

# json (`silly.encoding.json`)

`silly.encoding.json` 模块提供了高性能的 JSON 编码和解码功能。该模块是纯 Lua 实现,支持标准 JSON 数据类型的序列化和反序列化。

要使用此模块,您必须首先 `require` 它:
```lua
local json = require "silly.encoding.json"
```

---

## 核心概念

JSON (JavaScript Object Notation) 是一种轻量级的数据交换格式。该模块支持在 Lua 数据结构和 JSON 字符串之间进行转换:

- **编码 (encode)**: 将 Lua 表转换为 JSON 字符串
- **解码 (decode)**: 将 JSON 字符串解析为 Lua 表

### 类型映射

Lua 和 JSON 之间的类型映射关系:

| Lua 类型 | JSON 类型 | 说明 |
|---------|----------|------|
| `table` (数组) | Array | 表的第一个元素存在或表为空时视为数组 |
| `table` (对象) | Object | 表为哈希表结构时视为对象 |
| `string` | String | 字符串会自动转义特殊字符 |
| `number` | Number | 支持整数和浮点数 |
| `boolean` | Boolean | `true` 和 `false` |
| `nil` | `null` | JSON 的 `null` 解码为 Lua 的 `nil` |

---

## 完整示例

```lua validate
local json = require "silly.encoding.json"

-- 1. 基本类型编码
local simple = {
    name = "Alice",
    age = 30,
    active = true,
    score = 95.5
}
local encoded = json.encode(simple)
print("编码结果:", encoded)
-- 输出: {"name":"Alice","age":30,"active":true,"score":95.5}

-- 2. 数组编码
local arr = {1, 2, 3, "hello", true}
print("数组编码:", json.encode(arr))
-- 输出: [1,2,3,"hello",true]

-- 3. 嵌套结构编码
local nested = {
    user = {
        name = "Bob",
        tags = {"developer", "gamer"}
    },
    settings = {
        theme = "dark",
        notifications = true
    }
}
local nested_json = json.encode(nested)
print("嵌套编码:", nested_json)

-- 4. JSON 解码
local json_str = '{"name":"Charlie","age":25,"hobbies":["reading","coding"]}'
local obj, pos = json.decode(json_str)
if obj then
    print("姓名:", obj.name)
    print("年龄:", obj.age)
    print("爱好:", table.concat(obj.hobbies, ", "))
end

-- 5. 处理特殊字符
local special = {
    text = 'Line1\nLine2\t"quoted"'
}
local escaped = json.encode(special)
print("转义编码:", escaped)
-- 输出: {"text":"Line1\nLine2\t\"quoted\""}

local decoded_special = json.decode(escaped)
assert(decoded_special.text == special.text)

-- 6. 错误处理
local invalid_json = '{"incomplete":'
local result, err = json.decode(invalid_json)
if not result then
    print("解码失败:", err)
end
```

---

## API 参考

### 编码函数

#### `json.encode(obj)`
将 Lua 表编码为 JSON 字符串。

- `obj` (表): 要编码的 Lua 表。只支持表类型作为顶层对象。
- **返回**: 编码后的 JSON 字符串。

**支持的数据类型**:
- `string`: 字符串,会自动转义特殊字符 (`"`, `\`, `\b`, `\f`, `\n`, `\r`, `\t`)
- `number`: 数字(整数和浮点数)
- `boolean`: 布尔值 (`true`/`false`)
- `table`: 表(作为数组或对象)

**数组与对象的判断**:
- 如果表的第一个元素 (`[1]`) 存在,或表为空,则编码为 JSON 数组
- 否则编码为 JSON 对象

**示例**:
```lua validate
local json = require "silly.encoding.json"

-- 对象编码
local obj = {name = "test", value = 42}
print(json.encode(obj))
-- 输出: {"name":"test","value":42}

-- 数组编码
local arr = {1, 2, 3}
print(json.encode(arr))
-- 输出: [1,2,3]

-- 空表编码为空数组
print(json.encode({}))
-- 输出: []

-- 嵌套结构
local nested = {
    items = {
        {id = 1, name = "item1"},
        {id = 2, name = "item2"}
    }
}
print(json.encode(nested))
-- 输出: {"items":[{"id":1,"name":"item1"},{"id":2,"name":"item2"}]}
```

---

### 解码函数

#### `json.decode(str)`
将 JSON 字符串解析为 Lua 表。

- `str` (字符串): 要解析的 JSON 字符串。
- **返回**:
  - 成功时: 返回解析后的 Lua 表和结束位置 `(obj, pos)`
  - 失败时: 返回 `nil, error` (错误信息)

**支持的 JSON 类型**:
- Object: 解码为 Lua 表(哈希表)
- Array: 解码为 Lua 表(数组)
- String: 解码为 Lua 字符串,自动处理转义序列
- Number: 解码为 Lua 数字,支持科学计数法
- Boolean: `true`/`false` 解码为 Lua 布尔值
- `null`: 解码为 Lua 的 `nil`

**示例**:
```lua validate
local json = require "silly.encoding.json"

-- 解码对象
local obj, pos = json.decode('{"name":"Alice","age":30}')
print(obj.name, obj.age)
-- 输出: Alice  30

-- 解码数组
local arr = json.decode('[1,2,3,4,5]')
print(arr[1], arr[3])
-- 输出: 1  3

-- 解码 null
local with_null = json.decode('{"value":null}')
print(with_null.value == nil)
-- 输出: true

-- 科学计数法
local scientific = json.decode('{"number":-1.23e5}')
print(scientific.number)
-- 输出: -123000.0

-- 错误处理
local invalid, err = json.decode('{"bad":}')
if not invalid then
    print("解析失败:", err)
end
```

---

## 特殊字符处理

该模块会自动处理 JSON 中的转义字符:

### 编码时转义

编码时,以下字符会被自动转义:

| 字符 | 转义序列 | 说明 |
|-----|---------|------|
| `"` | `\"` | 双引号 |
| `\` | `\\` | 反斜杠 |
| `\b` | `\\b` | 退格 |
| `\f` | `\\f` | 换页 |
| `\n` | `\\n` | 换行 |
| `\r` | `\\r` | 回车 |
| `\t` | `\\t` | 制表符 |

### 解码时反转义

解码时,JSON 中的转义序列会被自动转换为相应的字符。

**示例**:
```lua validate
local json = require "silly.encoding.json"

-- 编码转义字符
local text = {
    message = 'Hello\nWorld\t"quoted"'
}
local encoded = json.encode(text)
print("编码:", encoded)
-- 输出: {"message":"Hello\\nWorld\\t\\"quoted\\""}

-- 解码转义字符
local decoded = json.decode(encoded)
print("解码:", decoded.message)
-- 输出: Hello
--       World  "quoted"

-- 反斜杠处理
local backslash = {path = "C:\\Users\\test"}
local bs_encoded = json.encode(backslash)
print("路径编码:", bs_encoded)
-- 输出: {"path":"C:\\\\Users\\\\test"}

local bs_decoded = json.decode(bs_encoded)
assert(bs_decoded.path == backslash.path)
```

---

## 高级用法

### 处理大型数据

该模块可以处理大型 JSON 数据和深层嵌套结构:

```lua validate
local json = require "silly.encoding.json"

-- 长字符串处理
local long_str = string.rep("a", 10000)
local encoded = json.encode({data = long_str})
local decoded = json.decode(encoded)
assert(decoded.data == long_str)
print("长字符串测试通过")

-- 深层嵌套
local deep = {}
local current = deep
for i = 1, 50 do
    current[1] = {}
    current = current[1]
end

local deep_encoded = json.encode(deep)
local deep_decoded = json.decode(deep_encoded)
print("深层嵌套测试通过")

-- 大数组
local large_arr = {}
for i = 1, 1000 do
    large_arr[i] = i
end
local arr_encoded = json.encode(large_arr)
local arr_decoded = json.decode(arr_encoded)
assert(#arr_decoded == 1000)
print("大数组测试通过")
```

### 稀疏数组处理

注意: Lua 的稀疏数组在编码时只会包含连续的数组部分:

```lua validate
local json = require "silly.encoding.json"

-- 稀疏数组
local sparse = {[1] = 1, [3] = 3}  -- 缺少 [2]
local encoded = json.encode(sparse)
print("稀疏数组编码:", encoded)
-- 输出: [1]  (只包含连续部分)

-- 混合数组/对象
local mixed = {[1] = "first", name = "test"}
local mixed_encoded = json.encode(mixed)
print("混合结构:", mixed_encoded)
-- 输出: ["first"]  (当 [1] 存在时视为数组)
```

### 错误处理模式

解码时始终检查返回值:

```lua validate
local json = require "silly.encoding.json"

local test_cases = {
    '{"valid":true}',           -- 有效
    '{"missing":',              -- 缺少右括号
    '[1,,2]',                   -- 无效逗号
    '{"empty":}',               -- 空值
    '{"wrong":tru}',            -- 无效布尔值
}

for i, json_str in ipairs(test_cases) do
    local obj, err = json.decode(json_str)
    if obj then
        print(string.format("测试 %d: 解码成功", i))
    else
        print(string.format("测试 %d: 解码失败 - %s", i, err))
    end
end
```

---

## 注意事项

### 1. 类型限制

- **不支持的类型**: 函数、userdata、thread 等类型不能被编码
- **顶层类型**: `json.encode()` 只接受表类型作为参数
- **nil 值**: 对象中的 `nil` 值会在编码时被忽略

### 2. 数组 vs 对象

判断规则:
- 如果 `table[1] ~= nil` 或 `next(table) == nil`,则视为数组
- 否则视为对象

这意味着:
```lua
{}                    -- 编码为 []
{1, 2, 3}            -- 编码为 [1,2,3]
{[1]=1, [3]=3}       -- 编码为 [1] (稀疏数组只取连续部分)
{name="test"}        -- 编码为 {"name":"test"}
{[1]=1, name="test"} -- 编码为 [1] (有 [1] 时视为数组)
```

### 3. 数字精度

- 支持 Lua 的完整数字范围
- 支持科学计数法 (如 `1.23e5`)
- 非常大的数字可能会损失精度 (受浮点数限制)

### 4. Unicode 支持

- UTF-8 字符串可以正常处理
- 中文等 Unicode 字符会被直接编码,不会转换为 `\uXXXX` 格式

### 5. 性能考虑

- 纯 Lua 实现,性能适合大多数应用场景
- 对于极高性能要求,可考虑使用 C 实现的 JSON 库
- 避免编码过深的嵌套结构以保持性能

### 6. 线程安全

- 该模块是无状态的,可以在不同协程中安全使用
- 每次调用 `encode/decode` 都是独立的

---

## 实用示例

### HTTP API 响应

```lua validate
local json = require "silly.encoding.json"

-- 构建 API 响应
local function api_response(success, data, message)
    return json.encode({
        success = success,
        data = data,
        message = message or "",
        timestamp = os.time()
    })
end

-- 成功响应
local success_resp = api_response(true, {
    user = {id = 123, name = "Alice"},
    items = {1, 2, 3}
}, "操作成功")
print("成功响应:", success_resp)

-- 错误响应
local error_resp = api_response(false, nil, "未找到用户")
print("错误响应:", error_resp)
```

### 配置文件处理

```lua validate
local json = require "silly.encoding.json"

-- 配置对象
local config = {
    server = {
        host = "127.0.0.1",
        port = 8080,
        timeout = 30
    },
    database = {
        host = "localhost",
        port = 3306,
        name = "mydb"
    },
    features = {
        "logging",
        "caching",
        "monitoring"
    }
}

-- 保存配置 (实际使用时写入文件)
local config_json = json.encode(config)
print("配置 JSON:", config_json)

-- 加载配置
local loaded_config = json.decode(config_json)
print("服务器端口:", loaded_config.server.port)
print("数据库名称:", loaded_config.database.name)
```

### 数据校验

```lua validate
local json = require "silly.encoding.json"

-- 验证 JSON 格式
local function validate_json(json_str)
    local obj, err = json.decode(json_str)
    if not obj then
        return false, "JSON 格式错误: " .. (err or "unknown")
    end

    -- 验证必需字段
    if not obj.name or not obj.age then
        return false, "缺少必需字段"
    end

    -- 验证类型
    if type(obj.age) ~= "number" then
        return false, "age 必须是数字"
    end

    return true, obj
end

-- 测试验证
local valid_json = '{"name":"Bob","age":25}'
local ok, result = validate_json(valid_json)
if ok then
    print("验证通过:", result.name)
end

local invalid_json = '{"name":"Bob"}'
local ok2, err2 = validate_json(invalid_json)
if not ok2 then
    print("验证失败:", err2)
end
```

---

## 相关模块

- **silly.net.http**: HTTP 协议实现,内部使用 JSON 处理请求/响应
- **silly.net.websocket**: WebSocket 协议,常用于传输 JSON 数据
- **silly.net.grpc**: gRPC 支持,可与 JSON 互补使用

---

## 另见

- [silly.encoding.base64](./base64.md): Base64 编码/解码
- [silly.net.http](../net/http.md): HTTP 服务器和客户端
- [silly.net.websocket](../net/websocket.md): WebSocket 协议支持
