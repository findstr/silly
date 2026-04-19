---
title: silly.adt.list
icon: list
category:
  - API Reference
tag:
  - Data Structure
  - List
---

# silly.adt.list

`silly.adt.list` is a doubly-linked list keyed by value. Insertion, removal, and lookup are all O(1), and values can act as cursors without holding onto external node handles. The trade-off: **each value can appear at most once** — duplicates raise an error.

## Module Import

```lua
local list = require "silly.adt.list"
```

## When to Use

- You need LRU-style ordering with frequent moves between ends.
- You want O(1) removal by value (rather than by index).
- Iteration order must reflect insertion order.

For a plain FIFO, prefer `silly.adt.queue` — it is cheaper and allows duplicates.

## API

### list.new()

Creates a new empty list.

- **Returns**: `silly.adt.list`

### list:pushback(v)

Appends `v` at the tail.

- **Parameters**: `v` — any non-nil value; must not already be in the list.
- **Errors**: raises if `v` is nil or already present.

### list:pushfront(v)

Prepends `v` at the head. Same constraints as `pushback`.

### list:popfront()

Removes and returns the head element, or `nil` if the list is empty.

### list:popback()

Removes and returns the tail element, or `nil` if the list is empty.

### list:remove(v)

Removes `v` from the list in O(1). Returns `nil, "removed"` if `v` is not present.

### list:front()

Returns the head value without removing it (or `nil` if empty).

### list:back()

Returns the tail value without removing it (or `nil` if empty).

### list:size()

Returns the number of elements.

### list:clear()

Removes all elements.

### list:values()

Returns an iterator over the list in head-to-tail order, suitable for `for v in list:values() do ... end`.

## Example: LRU

```lua
local list = require "silly.adt.list"

local function new_lru(capacity)
    local self = {
        keys = list.new(),
        values = {},
        capacity = capacity,
    }

    function self:get(k)
        local v = self.values[k]
        if v == nil then return nil end
        self.keys:remove(k)
        self.keys:pushback(k)  -- mark most-recently-used
        return v
    end

    function self:set(k, v)
        if self.values[k] ~= nil then
            self.keys:remove(k)
        elseif self.keys:size() >= self.capacity then
            local oldest = self.keys:popfront()
            self.values[oldest] = nil
        end
        self.values[k] = v
        self.keys:pushback(k)
    end

    return self
end

local cache = new_lru(3)
cache:set("a", 1); cache:set("b", 2); cache:set("c", 3)
cache:get("a")                 -- touches "a"
cache:set("d", 4)              -- evicts "b" (least recently used)
```

## Notes

- **Values are their own node handles** — do not push two equal values. Use wrapper tables (`{id=123}`) if you need duplicates.
- All operations are constant-time but not free; iteration and `clear` are O(n) as expected.
- Not thread-safe, but single-threaded business logic in silly makes that a non-issue.
