require("setupkoenv")

local plugin_path = "plugins/libra2perf.koplugin/?.lua"
if not package.path:find(plugin_path, 1, true) then
    package.path = plugin_path .. ";" .. package.path
end

local Preflight = require("preflight")

local ok, applied_or_err, reason = pcall(Preflight.run)
if not ok then
    io.stderr:write("Libra 2 preflight failed: ", tostring(applied_or_err), "\n")
elseif applied_or_err then
    io.write("Libra 2 preflight applied\n")
elseif reason then
    io.write("Libra 2 preflight skipped: ", tostring(reason), "\n")
end

return Preflight
