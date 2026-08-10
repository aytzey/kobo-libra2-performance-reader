local Preflight = {}

function Preflight.isLibra2Version(path)
    path = path or os.getenv("KO_LIBRA2_KOBO_VERSION") or "/mnt/onboard/.kobo/version"

    local file = io.open(path, "r")
    if not file then
        return false
    end

    local line = file:read("*l") or ""
    file:close()
    return line:gsub("%s+$", ""):match("388$") ~= nil
end

function Preflight.run(opts)
    opts = opts or {}

    if not opts.skip_model_check and not Preflight.isLibra2Version(opts.version_path) then
        return false, "not-libra2"
    end

    local DataStorage = require("datastorage")
    local defaults = opts.defaults or require("luadefaults"):open()
    local settings = opts.settings or require("luasettings"):open(
        DataStorage:getDataDir() .. "/settings.reader.lua")
    local tuning = opts.tuning or require("tuning")
    local gestures = opts.gestures
    if gestures == nil and opts.seed_gestures ~= false then
        gestures = tuning.openGestureSettings and tuning.openGestureSettings()
    end

    return tuning.apply(defaults, settings, nil, {
        force = opts.force,
        gestures = gestures,
    })
end

return Preflight
