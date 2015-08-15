local bp = require("binpacket")
local lp = require("linepacket")

local bpacket = nil

local spacker = {
        format = nil
}

local spacker_bp = nil

function spacker:create(format)
        if format == nil then
                format = self.format
        end

        assert(format == "binpacket" or format == "linepacket")

        if format == "binpacket" then
                if spacker_bp == nil then
                        spacker_bp = {
                                format = "binpacket",
                                packer = bp,
                                packer_inst = bp.create(),
                        }

                        self.__index = self
                        setmetatable(spacker_bp, self)
                end
                return spacker_bp;
        elseif format == "linepacket" then
                local t = {
                        format = "linepacket",
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

