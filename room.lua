local room = {

}

--TODO: t.mem will can occurs hole when the user exit the room
function room:create(uid)
        local t = {}
        self.__index = self
        setmetatable(t, self)
        t.owner = uid
        t.mem = {}
        t.mem[#t.mem + 1] = uid
        t.name = tostring(uid) .. " room"
        return t
end

function room:getname()
        return self.name
end

function room:getpersoncnt()
        local cnt
        assert(self.owner)
        return 1 + #self.mem
end

function room:handler(msg)

end


return room


