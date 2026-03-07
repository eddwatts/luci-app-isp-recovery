-- LuCI Controller for ISP Recovery Wizard
-- Registers pages and handles AJAX calls from the wizard UI

module("luci.controller.isp_recovery", package.seeall)

function index()
    -- Add to the Network menu in LuCI
    entry({"admin", "network", "isp_recovery"},
          firstchild(),
          _("ISP Recovery"), 60)
    
    entry({"admin", "network", "isp_recovery", "wizard"},
          template("isp-recovery/wizard"),
          _("Credential Wizard"), 1)
    
    -- AJAX action endpoints
    entry({"admin", "network", "isp_recovery", "detect"},
          call("action_detect"), nil)
    
    entry({"admin", "network", "isp_recovery", "setup"},
          call("action_setup"), nil)
    
    entry({"admin", "network", "isp_recovery", "capture"},
          call("action_capture"), nil)
    
    entry({"admin", "network", "isp_recovery", "stop"},
          call("action_stop"), nil)
    
    entry({"admin", "network", "isp_recovery", "apply"},
          call("action_apply"), nil)
    
    entry({"admin", "network", "isp_recovery", "restore"},
          call("action_restore"), nil)
    
    entry({"admin", "network", "isp_recovery", "state"},
          call("action_state"), nil)
    
    entry({"admin", "network", "isp_recovery", "results"},
          call("action_results"), nil)
    
    entry({"admin", "network", "isp_recovery", "log"},
          call("action_log"), nil)
    
    entry({"admin", "network", "isp_recovery", "autotest"},
          call("action_autotest"), nil)

    entry({"admin", "network", "isp_recovery", "autotest_results"},
          call("action_autotest_results"), nil)
end

local function run_script(cmd)
    local handle = io.popen("/usr/bin/isp-recover.sh " .. cmd .. " 2>&1")
    local result = handle:read("*a")
    handle:close()
    return result
end

local function json_response(data)
    luci.http.prepare_content("application/json")
    luci.http.write(data)
end

function action_detect()
    local result = run_script("detect")
    -- Read the JSON output file
    local f = io.open("/tmp/isp-ifaces.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        json_response(content)
    else
        json_response('{"error":"Could not detect interfaces"}')
    end
end

function action_setup()
    local port = luci.http.formvalue("port") or "lan1"
    -- Sanitize input
    port = port:match("^[%w%-_]+$") and port or "lan1"
    local result = run_script("setup " .. port)
    json_response('{"status":"ok","message":"' .. result:gsub("\n","") .. '"}')
end

function action_capture()
    local port = luci.http.formvalue("port") or "lan1"
    port = port:match("^[%w%-_]+$") and port or "lan1"
    local result = run_script("capture " .. port)
    json_response('{"status":"ok","message":"Capture started"}')
end

function action_stop()
    run_script("stop")
    -- Wait briefly for analysis to complete
    os.execute("sleep 2")
    -- Return the results
    local f = io.open("/tmp/isp-results.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        json_response(content)
    else
        json_response('{"status":"error","error":"No results found"}')
    end
end

function action_apply()
    -- Collect editable values posted from the "edit before apply" form
    local function fv(k) return luci.http.formvalue(k) or "" end
    
    local env = string.format(
        "APPLY_AUTH_TYPE='%s' APPLY_USER='%s' APPLY_PASS='%s' " ..
        "APPLY_IP='%s' APPLY_GW='%s' APPLY_NM='%s' " ..
        "APPLY_DNS1='%s' APPLY_DNS2='%s' APPLY_MAC='%s' APPLY_VLAN='%s'",
        fv("auth_type"):gsub("'",""),
        fv("username"):gsub("'",""),
        fv("password"):gsub("'",""),
        fv("ip"):gsub("'",""),
        fv("gateway"):gsub("'",""),
        fv("netmask"):gsub("'",""),
        fv("dns1"):gsub("'",""),
        fv("dns2"):gsub("'",""),
        fv("mac"):gsub("'",""),
        fv("vlan"):gsub("'","")
    )
    
    local handle = io.popen(env .. " /usr/bin/isp-recover.sh apply 2>&1")
    local result = handle:read("*a")
    handle:close()
    json_response('{"status":"ok","message":"Settings applied, network restarting..."}')
end

function action_restore()
    local result = run_script("restore")
    json_response('{"status":"ok","message":"Original config restored"}')
end

function action_state()
    local f = io.open("/tmp/isp-recovery.state", "r")
    local state = f and f:read("*l") or "idle"
    if f then f:close() end
    json_response('{"state":"' .. state .. '"}')
end

function action_results()
    local f = io.open("/tmp/isp-results.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        json_response(content)
    else
        json_response('{"status":"no_results"}')
    end
end

function action_log()
    local lines = luci.http.formvalue("lines") or "50"
    lines = tonumber(lines) or 50
    lines = math.min(lines, 200)
    
    local f = io.open("/tmp/isp-recovery.log", "r")
    if f then
        local all_lines = {}
        for line in f:lines() do
            table.insert(all_lines, line)
        end
        f:close()
        -- Return last N lines
        local start = math.max(1, #all_lines - lines + 1)
        local result = {}
        for i = start, #all_lines do
            table.insert(result, all_lines[i])
        end
        luci.http.prepare_content("text/plain")
        luci.http.write(table.concat(result, "\n"))
    else
        luci.http.prepare_content("text/plain")
        luci.http.write("No log yet")
    end
end

function action_autotest()
    -- Run in background so the HTTP request can return immediately
    -- Progress is polled via action_autotest_results
    os.execute("/usr/bin/isp-recover.sh autotest >> /tmp/isp-recovery.log 2>&1 &")
    json_response('{"status":"started","message":"Auto-test sequence running in background"}')
end

function action_autotest_results()
    local f = io.open("/tmp/isp-autotest.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        json_response(content)
    else
        json_response('{"status":"not_started"}')
    end
end

function action_cleanup()
    run_script("cleanup")
    json_response('{"status":"ok"}')
end
