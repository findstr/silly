---@alias core.metrics.metric core.metrics.gauge | core.metrics.gaugevec | core.metrics.counter | core.metrics.countervec | core.metrics.histogram | core.metrics.histogramvec

---@class core.metrics.collector
---@field name string
---@field new fun(): core.metrics.collector
---@field collect fun(self: core.metrics.collector, buf: core.metrics.metric[])