---
title: silly.debugger
icon: bug
category:
  - API参考
tag:
  - 工具
  - 调试
  - 开发
---

# silly.debugger

交互式Lua调试器，支持断点、单步执行、变量查看、堆栈回溯等功能，可在运行时对Lua代码进行调试。

## 模块导入

```lua validate
local debugger = require "silly.debugger"
```

## API

### debugger.start(read, write)
启动调试器会话。

- **参数**:
  - `read`: `function() -> string|nil` - 读取函数，返回一行输入，或nil表示连接断开
  - `write`: `function(data: string|table)` - 写入函数，将数据发送给客户端
- **返回值**: `string|nil` - 调试会话结束信息，或nil表示出错
- **说明**:
  - 调试器是独占的，同一时间只能有一个调试会话
  - 调试器会hook所有活跃的协程
  - 退出调试器后，所有hook会被清除

## 调试命令

进入调试器后，可以使用以下命令：

### h (help)
显示命令帮助。

- **语法**: `h`

### b (breakpoint)
设置断点。

- **语法**: `b [filename] [line]`
- **参数**:
  - `filename`: `string` (可选) - 文件名，默认使用当前文件
  - `line`: `integer` - 行号
- **返回**: 断点ID（如 `$1`, `$2`）
- **示例**:
```
debugger> b main.lua 42
Breakpoint $1 at file:main.lua, line:42

debugger> b 50
Breakpoint $2 at file:main.lua, line:50
```

### d (delete)
删除断点。

- **语法**: `d [breakpoint_id]`
- **参数**:
  - `breakpoint_id`: `integer` (可选) - 断点ID，省略则删除所有断点
- **示例**:
```
debugger> d 1
Delete breakpoint $1

debugger> d
Delete breakpoint $ALL
```

### n (next)
单步执行（越过函数调用）。

- **语法**: `n`
- **说明**:
  - 执行当前行，如果有函数调用，不会进入函数内部
  - 只有在断点暂停时可用

### s (step)
单步执行（步入函数调用）。

- **语法**: `s`
- **说明**:
  - 执行当前行，如果有函数调用，会进入函数内部
  - 只有在断点暂停时可用

### c (continue)
继续执行程序。

- **语法**: `c`
- **说明**:
  - 继续执行直到遇到下一个断点
  - 只有在断点暂停时可用

### p (print)
打印变量的值。

- **语法**: `p <variable_name>`
- **参数**:
  - `variable_name`: `string` - 变量名
- **说明**:
  - 按顺序查找：局部变量 → upvalue → 全局变量
  - 支持打印表、字符串、数字等所有类型
  - 只有在断点暂停时可用
- **示例**:
```
debugger> p user_id
Param $1 user_id = 12345

debugger> p config
Upvalue $1 config = {['host'] = 'localhost',['port'] = 8080,}

debugger> p print
Global $_ENV print = function: 0x12345678
```

### bt (backtrace)
打印当前协程的堆栈回溯。

- **语法**: `bt`
- **说明**:
  - 显示完整的调用栈
  - 只有在断点暂停时可用

### q (quit)
退出调试器。

- **语法**: `q`
- **说明**:
  - 清除所有断点
  - 恢复所有协程的正常执行
  - 关闭调试会话

## 使用示例

### 示例1：通过console启动调试器

`silly.console` 模块内置了DEBUG命令来启动调试器：

```lua validate
local console = require "silly.console"

console({
    addr = "127.0.0.1:8888"
})

print("Console started, use 'telnet 127.0.0.1 8888' and type 'DEBUG' to start debugger")
```

通过telnet连接并启动调试器：

```
$ telnet 127.0.0.1 8888
console> debug

debugger> h
List of commands:
b: Insert a break point [b 'filename linenumber']
d: Delete a break point [d 'breakpoint id']
n: Step next line, it will over the call [n]
s: Step next line, it will into the call [s]
c: Continue program being debugged [c]
p: Print variable include local/up/global values [p name]
bt: Print backtrace of all stack frames [bt]
q: Quit debug mode [q]
```

### 示例2：设置断点并调试

```
debugger> b main.lua 100
Breakpoint $1 at file:main.lua, line:100

debugger> c
(程序继续运行直到断点...)

debugger main.lua main.lua:100> p request
Param $1 request = {['method'] = 'GET',['path'] = '/api/users',}

debugger main.lua main.lua:100> bt
stack traceback:
        [C]: in function 'breakin'
        main.lua:100: in function 'handle_request'
        main.lua:50: in function <main.lua:45>
        ...

debugger main.lua main.lua:100> n
(执行下一行)

debugger main.lua main.lua:101> s
(步入函数)

debugger utils.lua utils.lua:25> p data
Param $1 data = 'hello world'

debugger utils.lua utils.lua:25> c
(继续执行)
```

### 示例3：自定义调试接口

可以为自定义协议实现调试接口：

```lua validate
local silly = require "silly"
local debugger = require "silly.debugger"
local tcp = require "silly.net.tcp"

-- 启动调试服务器
tcp.listen("127.0.0.1:9999", function(fd, addr)
    print("Debugger connected:", addr)

    -- 定义读写函数
    local read = function()
        return tcp.readline(fd)
    end

    local write = function(data)
        tcp.write(fd, data)
    end

    -- 启动调试会话
    local result = debugger.start(read, write)

    if result then
        print("Debug session ended:", result)
    else
        print("Debug session error")
    end

    tcp.close(fd)
end)

print("Debugger listening on 127.0.0.1:9999")
```

### 示例4：调试定时任务

假设有定时任务代码：

```lua
local time = require "silly.time"

local function timer_task()
    local count = 0
    while true do
        count = count + 1
        print("Timer tick:", count)
        time.sleep(1000)
        -- 想在这里设置断点
    end
end

silly.fork(timer_task)
```

调试步骤：

```
debugger> b timer.lua 7
Breakpoint $1 at file:timer.lua, line:7

debugger> c
(等待定时器触发...)

debugger timer.lua timer.lua:7> p count
Param $1 count = 5

debugger timer.lua timer.lua:7> n
(执行下一行)

debugger timer.lua timer.lua:8> c
(继续执行)
```

### 示例5：查看表结构

```
debugger> p config
Upvalue $1 config = {
  ['server'] = {
    ['host'] = 'localhost',
    ['port'] = 8080,
  },
  ['database'] = {
    ['host'] = 'db.example.com',
    ['name'] = 'mydb',
  },
}
```

### 示例6：调试网络请求处理

```lua
local tcp = require "silly.net.tcp"

tcp.listen("0.0.0.0:8080", function(fd, addr)
    local data = tcp.read(fd, 1024)
    -- 在这里设置断点检查接收到的数据
    local response = process_request(data)
    tcp.write(fd, response)
    tcp.close(fd)
end)
```

调试：

```
debugger> b handler.lua 5
Breakpoint $1 at file:handler.lua, line:5

debugger> c
(等待客户端连接...)

debugger handler.lua handler.lua:5> p data
Param $1 data = 'GET /api/users HTTP/1.1\r\n...'

debugger handler.lua handler.lua:5> p addr
Param $2 addr = '192.168.1.100:54321'

debugger handler.lua handler.lua:5> s
(步入 process_request 函数)
```

## 实现细节

### Hook机制

调试器使用Lua的debug hook机制实现：

- **call hook**: 检测函数调用，判断是否需要启用line hook
- **line hook**: 检查每行代码，判断是否命中断点
- **return hook**: 跟踪调用栈深度

### 断点检测

断点通过以下方式检测：

1. 检查源文件名是否匹配（支持后缀匹配）
2. 检查行号是否在函数定义范围内
3. 检查当前执行行是否等于断点行

### 协程管理

- 调试器会hook所有活跃的协程
- 当创建新协程时，自动添加hook
- 当协程结束时，自动移除hook
- 使用 `silly.task_hook()` 实现协程生命周期监听

### 锁定线程

当断点触发时：

- 当前协程被"锁定"（暂停执行）
- 其他协程继续正常运行
- 只有锁定的协程可以使用 `n`/`s`/`c`/`p`/`bt` 命令
- 命令提示符显示当前文件和行号

## 注意事项

::: warning 性能影响
调试器会显著降低程序性能，因为需要hook每次函数调用和行执行。不要在生产环境中启用调试器。
:::

::: warning 并发限制
同一时间只能有一个调试会话。如果已有调试器运行，新的调试请求会被拒绝。
:::

::: tip 断点生效时机
设置断点后需要执行 `c` 命令才能生效。断点在函数下次调用时才会被检查。
:::

::: tip 文件名匹配
断点的文件名支持后缀匹配，所以 `b main.lua 10` 可以匹配 `/path/to/main.lua`。
:::

## 限制

1. **C函数**: 无法调试C函数内部，只能看到C函数的调用
2. **尾调用**: 尾调用优化可能导致堆栈信息不完整
3. **字符串转义**: 变量值中的特殊字符会被转义显示（如 `\n`, `\x00`）
4. **循环引用**: 表的循环引用只显示第一次，避免无限递归
5. **大表**: 非常大的表可能导致输出过多，建议只查看特定字段

## 与console的集成

`silly.console` 模块内置了 `DEBUG` 命令：

```lua
function console.debug(fd)
    local read = function()
        return tcp.readline(fd)
    end
    local write = function(dat)
        return tcp.write(fd, dat)
    end
    return debugger.start(read, write)
end
```

这使得通过console进入调试器非常方便。

## 参见

- [silly.console](./console.md) - 控制台命令行
- [silly.logger](./logger.md) - 日志系统
- [Lua Debug Library](https://www.lua.org/manual/5.4/manual.html#6.10) - Lua调试库文档
