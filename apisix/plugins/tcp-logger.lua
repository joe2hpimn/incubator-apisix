--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core     = require("apisix.core")
local log_util = require("apisix.utils.log-util")
local batch_processor = require("apisix.utils.batch-processor")
local plugin_name = "tcp-logger"
local tostring = tostring
local buffers = {}
local ngx = ngx
local tcp = ngx.socket.tcp

local schema = {
    type = "object",
    properties = {
        host = {type = "string"},
        port = {type = "integer", minimum = 0},
        tls = {type = "boolean", default = false},
        tls_options = {type = "string"},
        timeout = {type = "integer", minimum = 1, default= 1000},
        name = {type = "string", default = "tcp logger"},
        max_retry_count = {type = "integer", minimum = 0, default = 0},
        retry_delay = {type = "integer", minimum = 0, default = 1},
        buffer_duration = {type = "integer", minimum = 1, default = 60},
        inactive_timeout = {type = "integer", minimum = 1, default = 5},
        batch_max_size = {type = "integer", minimum = 1, default = 1000},
    },
    required = {"host", "port"}
}


local _M = {
    version = 0.1,
    priority = 405,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function send_tcp_data(conf, log_message)
    local err_msg
    local res = true
    local sock, soc_err = tcp()

    if not sock then
        return false, "failed to init the socket" .. soc_err
    end

    sock:settimeout(conf.timeout)

    local ok, err = sock:connect(conf.host, conf.port)
    if not ok then
        return false, "failed to connect to TCP server: host[" .. conf.host
                      .. "] port[" .. tostring(conf.port) .. "] err: " .. err
    end

    if conf.tls then
        ok, err = sock:sslhandshake(true, conf.tls_options, false)
        if not ok then
            return false, "failed to to perform TLS handshake to TCP server: host["
                          .. conf.host .. "] port[" .. tostring(conf.port) .. "] err: " .. err
        end
    end

    ok, err = sock:send(log_message)
    if not ok then
        res = false
        err_msg = "failed to send data to TCP server: host[" .. conf.host
                  .. "] port[" .. tostring(conf.port) .. "] err: " .. err
    end

    ok, err = sock:close()
    if not ok then
        core.log.error("failed to close the TCP connection, host[",
                        conf.host, "] port[", conf.port, "] ", err)
    end

    return res, err_msg
end


function _M.log(conf)
    local entry = log_util.get_full_log(ngx)

    if not entry.route_id then
        core.log.error("failed to obtain the route id for tcp logger")
        return
    end

    local log_buffer = buffers[entry.route_id]

    if log_buffer then
        log_buffer:push(entry)
        return
    end

    -- Generate a function to be executed by the batch processor
    local func = function(entries, batch_max_size)
        local data, err
        if batch_max_size == 1 then
            data, err = core.json.encode(entries[1]) -- encode as single {}
        else
            data, err = core.json.encode(entries) -- encode as array [{}]
        end

        if not data then
            core.log.error('error occurred while encoding the token: ', err)
        end

        return send_tcp_data(conf, data)
    end

    local config = {
        name = conf.name,
        retry_delay = conf.retry_delay,
        batch_max_size = conf.batch_max_size,
        max_retry_count = conf.max_retry_count,
        buffer_duration = conf.buffer_duration,
        inactive_timeout = conf.inactive_timeout,
    }

    local err
    log_buffer, err = batch_processor:new(func, config)

    if not log_buffer then
        core.log.error("error when creating the batch processor: ", err)
        return
    end

    buffers[entry.route_id] = log_buffer
    log_buffer:push(entry)
end

return _M
