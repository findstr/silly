local core = require "core"
local time = require "core.time"
local http = require "core.http"
local prometheus = require "core.metrics.prometheus"
local testaux = require "test.testaux"

-- Define metrics with the new 'xlabel'
local requests_total = prometheus.counter("my_app_requests_total", "Total number of requests.", {"xlabel"})
local network_errors_total = prometheus.counter("my_app_errors_total", "Total number of errors.", {"type", "xlabel"})

local active_users = prometheus.gauge("my_app_active_users", "Current number of active users.", {"xlabel"})
local server_temperature = prometheus.gauge("my_app_temperature_celsius", "Current server room temperature in Celsius.", {"location", "xlabel"})

local request_duration_seconds = prometheus.histogram("my_app_request_duration_seconds", "Request duration in seconds.", {"xlabel"})

-- Initialize some gauge values, now with the new label
active_users:labels("app?"):set(10)
server_temperature:labels("server_room", "app?"):set(25.5)

local server
local function start_prometheus_server()
    server = http.listen {
        addr = "0.0.0.0:9091", -- Common Prometheus scrape port
        handler = function(stream)
            if stream.path == "/metrics" then
                local metrics_data = prometheus.gather()
                stream:respond(200, {
                    ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
                    ["content-length"] = #metrics_data,
                })
                stream:close(metrics_data)
            else
                stream:respond(404, {["content-type"] = "text/plain"})
                stream:close("Not Found")
            end
        end
    }
    testaux.asserteq(not not server, true, "Prometheus server should start successfully")
    print("Prometheus metrics server listening on 127.0.0.1:9090/metrics")
end

local function update_metrics_periodically()
    local counter_tick = 0
    local gauge_tick = 0
    local histogram_tick = 0

    while true do
        -- Update Counter with the new label
        requests_total:labels("app?"):inc()
        counter_tick = counter_tick + 1
        if counter_tick % 5 == 0 then -- Increment network errors every 5 seconds
            network_errors_total:labels("network", "app?"):inc()
        end

        -- Update Gauge with the new label
        gauge_tick = gauge_tick + 1
        if gauge_tick % 3 == 0 then
            active_users:labels("app?"):add(math.random(-2, 3)) -- Fluctuate active users
            server_temperature:labels("server_room", "app?"):set(20 + math.random() * 10) -- Random temperature between 20 and 30
        end

        -- Update Histogram with the new label
        histogram_tick = histogram_tick + 1
        if histogram_tick % 2 == 0 then
            local duration = math.random() * 11
            request_duration_seconds:labels("app?"):observe(duration) -- Random duration between 0 and 5 seconds
            print("request_duration_seconds:observe", duration)
        end

        time.sleep(1000) -- Sleep for 1 second
    end
end

-- Main execution
start_prometheus_server()
update_metrics_periodically()

-- The server will run indefinitely due to the while true loop in update_metrics_periodically
-- In a real test scenario, you might want to add a mechanism to stop the server after some time.
-- For this example, it's meant to run until manually stopped.

-- Cleanup (this part won't be reached in this continuous loop example, but good practice)
if server then
    server:close()
end