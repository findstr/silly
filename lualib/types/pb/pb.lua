---@meta pb

---@class pb.method
---@field name string
---@field client_streaming boolean
---@field server_streaming boolean
---@field input_type string
---@field output_type string

---@class pb.service
---@field name string
---@field method pb.method[]

---@class pb.proto
---@field package string
---@field service pb.service[]

---@class pb.state
---state object for managing protobuf decode/encode context
local state = {}

---@class pb.buffer
---Binary buffer for building protobuf messages
local buffer = {}

---Delete buffer and free resources
function buffer:delete() end

---Convert buffer content to hexadecimal string
---@param i integer? Start position (default: 1)
---@param j integer? End position (default: buffer length)
---@return string hex Hexadecimal representation
function buffer:tohex(i, j) end

---Load hexadecimal string into buffer
---@param hex string Hexadecimal string
---@param i integer? Start position in hex string
---@param j integer? End position in hex string
---@return pb.buffer self
function buffer:fromhex(hex, i, j) end

---Get buffer content as string
---@param i integer? Start position (default: 1)
---@param j integer? End position (default: buffer length)
---@return string result buffer content
function buffer:result(i, j) end

---Reset buffer with new content
---@param ... any Content to initialize buffer
---@return pb.buffer self
function buffer:reset(...) end

---Pack values into buffer using format string
---@param fmt string Pack format string
---@param ... any Values to pack
---@return pb.buffer self
function buffer:pack(fmt, ...) end

---@class pb.slice
---slice for reading protobuf messages
local slice = {}

---Delete slice and free resources
function slice:delete() end

---Convert slice content to hexadecimal string
---@param i integer? Start position (default: 1)
---@param j integer? End position (default: slice length)
---@return string hex Hexadecimal representation
function slice:tohex(i, j) end

---Load hexadecimal string into slice
---@param hex string Hexadecimal string
---@param i integer? Start position in hex string
---@param j integer? End position in hex string
---@return pb.slice self
function slice:fromhex(hex, i, j) end

---Get slice content as string
---@param i integer? Start position (default: 1)
---@param j integer? End position (default: slice length)
---@return string result Slice content
function slice:result(i, j) end

---Reset slice to point to new data
---@param data string? Data to slice
---@param i integer? Start position
---@param j integer? End position
---@return pb.slice self
function slice:reset(data, i, j) end

---Get or set nesting level
---@param n integer? New level to set
---@return integer level Current level
function slice:level(n) end

---Enter a nested message field
---@param i integer? Start position
---@param j integer? End position
---@return pb.slice self
function slice:enter(i, j) end

---Leave nested message(s)
---@param count integer? Number of levels to leave (default: 1)
---@return pb.slice self
function slice:leave(count) end

---Unpack values from slice using format string
---@param fmt string Unpack format string
---@param ... any Additional arguments
---@return ... any Unpacked values
function slice:unpack(fmt, ...) end

---@class pb.io
local io = {}

---Read data from file or stdin
---@param filename string? File to read (omit for stdin)
---@return string? data File content
---@return string? error Error message
function io.read(filename) end

---Write data to stdout
---@param ... string Data to write
---@return boolean success
function io.write(...) end

---Write data to file
---@param filename string Output file path
---@param ... string Data to write
---@return boolean success
function io.dump(filename, ...) end

---@class pb.conv
local conv = {}

---Encode int32 value
---@param value integer
---@return string encoded
function conv.encode_int32(value) end

---Encode uint32 value
---@param value integer
---@return string encoded
function conv.encode_uint32(value) end

---Encode sint32 value (zigzag encoding)
---@param value integer
---@return string encoded
function conv.encode_sint32(value) end

---Encode sint64 value (zigzag encoding)
---@param value integer
---@return string encoded
function conv.encode_sint64(value) end

---Decode uint32 value
---@param data string
---@return integer? value
---@return integer? pos Position after decode
function conv.decode_uint32(data) end

---Decode int32 value
---@param data string
---@return integer? value
---@return integer? pos Position after decode
function conv.decode_int32(data) end

---Decode sint32 value (zigzag encoding)
---@param data string
---@return integer? value
---@return integer? pos Position after decode
function conv.decode_sint32(data) end

---Decode sint64 value (zigzag encoding)
---@param data string
---@return integer? value
---@return integer? pos Position after decode
function conv.decode_sint64(data) end

---Encode float value
---@param value number
---@return string encoded
function conv.encode_float(value) end

---Encode double value
---@param value number
---@return string encoded
function conv.encode_double(value) end

---Decode float value
---@param data string
---@return number? value
---@return integer? pos Position after decode
function conv.decode_float(data) end

---Decode double value
---@param data string
---@return number? value
---@return integer? pos Position after decode
function conv.decode_double(data) end

---@class pb.unsafe
local unsafe = {}

---Load protobuf schema from memory pointer
---@param ptr userdata Memory pointer
---@param size integer Size of data
---@return boolean success
---@return integer? pos Position on error
function unsafe.load(ptr, size) end

---Decode protobuf message from memory pointer
---@param typename string Message type name
---@param ptr userdata Memory pointer
---@param size integer Size of data
---@param table table? Existing table to decode into
---@return table? message Decoded message
---@return string? error Error message
function unsafe.decode(typename, ptr, size, table) end

---Create slice from memory pointer
---@param ptr userdata Memory pointer
---@param size integer Size of data
---@return pb.slice slice
function unsafe.slice(ptr, size) end

---Convert Lua string to userdata pointer
---@param data string String data
---@return userdata ptr Memory pointer
---@return integer size Data size
function unsafe.touserdata(data) end

---Switch between global and local state
---@param mode "global"|"local" state mode
function unsafe.use(mode) end

---@class pb
local M = {}

---Clear loaded protobuf types
---@param typename string? Type to clear (omit to clear all)
function M.clear(typename) end

---Load protobuf schema from binary descriptor
---@param data string Binary FileDescriptorSet
---@return boolean success
---@return integer? pos Position in data on error
function M.load(data) end

---Load protobuf schema from file
---@param filename string Path to binary descriptor file
---@return boolean success
---@return integer? pos Position on error
function M.loadfile(filename) end

---Encode Lua table to protobuf binary format
---@param typename string Message type name
---@param data table Lua table to encode
---@param buffer pb.buffer? Optional buffer to use
---@return string? encoded Binary protobuf data
---@return string? error Error message
function M.encode(typename, data, buffer) end

---Decode protobuf binary to Lua table
---@param typename string Message type name
---@param data string? Binary protobuf data
---@param table table? Existing table to decode into
---@return table? message Decoded Lua table
---@return string? error Error message
function M.decode(typename, data, table) end

---Iterator over all registered message types
---@return fun(): string, string Iterator function
function M.types() end

---Iterator over fields of a message type
---@param typename string Message type name
---@return fun(): string, integer, string Iterator returning name, number, type
function M.fields(typename) end

---Get type information
---@param typename string Message type name
---@return string? name Full type name
---@return string? basename Short type name
---@return string? type Type category
function M.type(typename) end

---Get field information
---@param typename string Message type name
---@param field string|integer Field name or number
---@return string? name Field name
---@return integer? number Field number
---@return string? type Field type
---@return string? default_value Default value
---@return string? oneof Oneof name if applicable
function M.field(typename, field) end

---Get type format and wire type
---@param type string Type name
---@return string? format Format string
---@return integer? wiretype Wire type number
function M.typefmt(type) end

---Convert between enum name and number
---@param typename string Enum type name
---@param value string|integer Enum name or number
---@return string|integer? result Enum number or name
function M.enum(typename, value) end

---Enable or disable default values for a type
---@param typename string Message type name
---@param enable boolean? Enable/disable (omit to query)
---@return boolean enabled Current state
function M.defaults(typename, enable) end

---Set or get decode hook for a type
---@param typename string Message type name
---@param func function? Hook function (omit to query)
---@return function? hook Current hook function
function M.hook(typename, func) end

---Set or get encode hook for a type
---@param typename string Message type name
---@param func function? Hook function (omit to query)
---@return function? hook Current hook function
function M.encode_hook(typename, func) end

---Convert binary data to hexadecimal string
---@param data string Binary data
---@param i integer? Start position
---@param j integer? End position
---@return string hex Hexadecimal representation
function M.tohex(data, i, j) end

---Convert hexadecimal string to binary data
---@param hex string Hexadecimal string
---@param i integer? Start position
---@param j integer? End position
---@return string data Binary data
function M.fromhex(hex, i, j) end

---Extract substring from data
---@param data string Source data
---@param i integer? Start position
---@param j integer? End position
---@return string result Substring
function M.result(data, i, j) end

---Get protobuf library option
---@param name string Option name
---@return any value Option value
function M.option(name) end

---Get or set current state
---@param state pb.state? New state to set (omit to query)
---@return pb.state state Current state
function M.state(state) end

---Pack values into protobuf format
---@param typename string Message type name
---@param buffer pb.buffer? Optional buffer to use
---@param ... any Values to pack
---@return string packed Packed binary data
function M.pack(typename, buffer, ...) end

---Unpack values from protobuf format
---@param typename string Message type name
---@param data string Binary protobuf data
---@return ... any Unpacked values
function M.unpack(typename, data) end

M.Buffer = buffer
M.Slice = slice

---@type pb.io
M.io = io

---@type pb.conv
M.conv = conv

---@type pb.unsafe
M.unsafe = unsafe

return M
