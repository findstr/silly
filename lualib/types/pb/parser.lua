---@meta protoc

---@class protoc.parser
---@field typemap table<string, any> Type mapping table
---@field loaded table<string, any> Loaded modules
---@field paths table<string, boolean> Import search paths
---@field proto3_optional boolean Enable proto3 optional fields
---@field unknown_type boolean|function Handler for unknown types
---@field unknown_import boolean|function Handler for unknown imports
---@field on_import function? Import callback
---@field include_imports boolean Include imported files in descriptor
local parser = {}

---Create a new parser instance
---@return protoc.parser
function parser.new() end

---Parse protobuf source code
---@param source string Protobuf source code
---@param name string? Source name for error messages
---@return table parsed Parsed AST
function parser:parse(source, name) end

---Parse protobuf file
---@param filename string Path to .proto file
---@return table parsed Parsed AST
function parser:parsefile(filename) end

---Compile protobuf source to descriptor
---@param source string Protobuf source code
---@param name string? Source name for error messages
---@return string descriptor FileDescriptorSet in binary format
function parser:compile(source, name) end

---Compile protobuf file to descriptor
---@param filename string Path to .proto file
---@return string descriptor FileDescriptorSet in binary format
function parser:compilefile(filename) end

---Load and register protobuf schema
---@param source string Protobuf source code
---@param name string? Source name for error messages
---@return boolean success
---@return integer? position Position in source on error
function parser:load(source, name) end

---Load and register protobuf schema from file
---@param filename string Path to .proto file
---@return boolean success
---@return integer? position Position in source on error
function parser:loadfile(filename) end

---Add import search path
---@param path string Directory path to search for imports
---@return protoc.parser self
function parser:addpath(path) end

---Reset parser state
---@return protoc.parser self
function parser:reset() end