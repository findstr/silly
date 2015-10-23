local bp = require("binpacket")
local lp = require("linepacket")
local rp = require("rawpacket")

local bpacket = nil

local spacker = {
        mode = nil
}

local spacker_bp = nil
local spacker_rp = nil

local function create_once(self, mode, p, packer)
        if p == nil then
                p = {
                        mode = mode,
                        packer = packer,
                        packer_inst = packer:create(),
                }

                self.__index = self
                setmetatable(p, self)
        end
       
        return p;
end

function spacker:create(mode)
        if mode == nil then
                mode = self.mode
        end
        
        assert(mode == "bin" or mode == "line" or mode == "raw")

        if mode == "bin" then
                return create_once(self, mode, spacker_bp, bp)
        elseif mode == "raw" then
                return create_once(self, mode, spacker_rp, rp)
        elseif mode == "line" then
                local t = {
                        mode = "line",
                        packer = lp,
                        packer_inst = lp.create(),
                }

                self.__index = self
                setmetatable(t, self)

                return t
        end

        return nil
end
        
function spacker:push(fd, data, size)
        self.packer_inst = self.packer.push(self.packer_inst, fd, data, size)
end


function spacker:pop()
        return self.packer.pop(self.packer_inst);
end

function spacker:pack(data)
        return self.packer.pack(data)
end

return spacker

