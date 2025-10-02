---@alias silly.metrics.metric silly.metrics.gauge | silly.metrics.gaugevec | silly.metrics.counter | silly.metrics.countervec | silly.metrics.histogram | silly.metrics.histogramvec

---@class silly.metrics.collector
---@field name string
---@field new fun(): silly.metrics.collector
---@field collect fun(self: silly.metrics.collector, buf: silly.metrics.metric[])