local cjson_safe = require "cjson.safe"
local http = require "resty.http"
local jwt = require "resty.jwt"

-- string interpolation with named parameters in table
local function interp(s, tab)
    return (s:gsub('($%b{})', function(w) return tab[w:sub(3, -2)] or w end))
end

-- query "Get a Document (with Input)" endpoint from the OPA Data API
local function getDocument(input, conf)
    -- serialize the input into a string containing the JSON representation
    local json_body = assert(cjson_safe.encode({ input = input }))

    local opa_uri = interp("${protocol}://${host}:${port}/${base_path}/${decision}", {
        protocol = conf.server.protocol,
        host = conf.server.host,
        port = conf.server.port,
        base_path = conf.policy.base_path,
        decision = conf.policy.decision
    })

    local res, err = http.new():request_uri(opa_uri, {
        method = "POST",
        body = json_body,
        headers = {
          ["Content-Type"] = "application/json",
        },
        keepalive_timeout = conf.server.connection.timeout,
        keepalive_pool = conf.server.connection.pool
    })

    if err then
        error(err) -- failed to request the endpoint
    end

    -- deserialise the response into a Lua table
    return assert(cjson_safe.decode(res.body))
end

-- module
local _M = {}

function _M.execute(conf)
    local x_userinfo = ngx.req.get_headers()["X-Userinfo"]

    kong.log.info(interp("authorization header: ${value}", {
        value = x_userinfo
    }))
    -- decode JWT token
    local token = {}

    if x_userinfo then
        local userinfo = ngx.decode_base64(x_userinfo)
        if userinfo then
            token = assert(cjson_safe.decode(userinfo))
            kong.log.info(interp("Access requested for user ${subject}", {
                subject = token.sub
            }))
        end
    end

    -- get x-scope-tid header
    local scope = ""
    local xscope = ngx.req.get_headers()["X-Scope-Tid"]
    if xscope then
        scope = xscope
    end

    -- input document that will be send to opa
    local input = {
        token = token,
        method = ngx.var.request_method,
        path = ngx.var.upstream_uri,
        scope = scope
    }

    local status, res = pcall(getDocument, input, conf)

    if not status then
        kong.log.err("Failed to get document: ", res)
        return kong.response.exit(500, [[{"message":"Oops, something went wrong"}]])
    end

    -- when the policy fail, 'result' is omitted
    if not res.result then
        kong.log.info("Access forbidden")
        return kong.response.exit(403, [[{"message":"Access Forbidden"}]])
    end

    -- access allowed
--    kong.log.debug(interp("Access allowed to ${method} ${path} for user ${subject}", {
    kong.log.debug(interp("Access allowed to ${method} ${path} for user", {
        method = input.method,
        path = input.path
        -- subject = token.payload.sub
    }))
end

return _M