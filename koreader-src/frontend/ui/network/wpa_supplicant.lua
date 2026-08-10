--[[--
WPA client helper for Kobo.
]]

local crypto = require("ffi/crypto")
local bin_to_hex = require("ffi/sha2").bin_to_hex
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local WpaClient = require("lj-wpaclient/wpaclient")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = FFIUtil.template

local CLIENT_INIT_ERR_MSG = _("Failed to initialize network control client: %1.")
local CTRL_INTERFACE_DIR = "/var/run/wpa_supplicant"
local DEFAULT_WIFI_CTRL_INTERFACE = CTRL_INTERFACE_DIR .. "/wlan0"

local WpaSupplicant = {}

local function isNonWifiCtrlInterface(ctrl_interface)
    return type(ctrl_interface) ~= "string"
        or ctrl_interface == ""
        or ctrl_interface:match("/eth%d+$") ~= nil
        or ctrl_interface:match("/usb%d+$") ~= nil
end

function WpaSupplicant:_resolveCtrlInterface(force_probe)
    local configured = self.wpa_supplicant and self.wpa_supplicant.ctrl_interface
    if not force_probe and not isNonWifiCtrlInterface(configured) and util.pathExists(configured) then
        return configured
    end

    local candidates = { DEFAULT_WIFI_CTRL_INTERFACE }
    local ok, iter, dir_obj = pcall(lfs.dir, CTRL_INTERFACE_DIR)
    if ok and iter then
        for entry in iter, dir_obj do
            if entry:match("^wlan%d+$") and entry ~= "wlan0" then
                candidates[#candidates + 1] = CTRL_INTERFACE_DIR .. "/" .. entry
            end
        end
    end
    if not isNonWifiCtrlInterface(configured) then
        candidates[#candidates + 1] = configured
    end

    for _, candidate in ipairs(candidates) do
        if util.pathExists(candidate) then
            self.wpa_supplicant.ctrl_interface = candidate
            return candidate
        end
    end

    local fallback = isNonWifiCtrlInterface(configured) and DEFAULT_WIFI_CTRL_INTERFACE or configured
    self.wpa_supplicant.ctrl_interface = fallback
    return fallback
end

function WpaSupplicant:_newWpaClient()
    local ctrl_interface = self:_resolveCtrlInterface(false)
    local wcli, err = WpaClient.new(ctrl_interface)
    if wcli then
        return wcli
    end

    local retry_ctrl_interface = self:_resolveCtrlInterface(true)
    if retry_ctrl_interface ~= ctrl_interface then
        logger.warn("WpaSupplicant: retrying control interface", retry_ctrl_interface, "after", ctrl_interface, "failed:", err)
        wcli, err = WpaClient.new(retry_ctrl_interface)
    end
    return wcli, err
end

local function decodeSSID(ssid)
    local decode = function(b)
        local c = string.char(tonumber(b, 16))
        -- This is a hack that allows us to make sure that any decoded backslash
        -- does not get replaced in the step that replaces double backslashes.
        if c == "\\" then
            return "\\\\"
        else
            return c
        end
    end

    local decoded = ssid:gsub("%f[\\]\\x(%x%x)", decode)
    decoded = decoded:gsub("\\\\", "\\")
    return decoded
end

--- Gets network list.
function WpaSupplicant:getNetworkList()
    local wcli, err = self:_newWpaClient()
    if wcli == nil then
        return nil, T(CLIENT_INIT_ERR_MSG, err)
    end

    local list
    list, err = wcli:scanThenGetResults()
    wcli:close()
    if list == nil then
        return nil, T("An error occurred while scanning: %1.", err)
    end

    local saved_networks = self:getAllSavedNetworks()
    local curr_network = self:getCurrentNetwork()

    for _, network in ipairs(list) do
        network.ssid = decodeSSID(network.ssid)
        network.signal_quality = network:getSignalQuality()
        local saved_nw = saved_networks:readSetting(network.ssid)
        if saved_nw then
            --- @todo verify saved_nw.flags == network.flags?
            -- This will break if user changed the network setting, e.g.,
            -- from [WPA-PSK-TKIP+CCMP][WPS][ESS]
            --   to [WPA-PSK-TKIP+CCMP][ESS]
            network.password = saved_nw.password
            network.psk = saved_nw.psk
        end
        if curr_network and curr_network.ssid == network.ssid and (curr_network.bssid == "any" or curr_network.bssid == network.bssid) then
            network.connected = true
            network.wpa_supplicant_id = curr_network.id
            logger.dbg("WpaSupplicant:getNetworkList: automatically connected to network", util.fixUtf8(curr_network.ssid, "�"))
        end
    end
    return list
end

local function calculatePsk(ssid, pwd)
    return bin_to_hex(crypto.pbkdf2_hmac_sha1(pwd, ssid, 4096, 32))
end

--- Authenticates network.
function WpaSupplicant:authenticateNetwork(network, options)
    local wcli, reply, err
    options = options or {}
    local max_retry = tonumber(options.max_retry) or 30
    local wait_ms = tonumber(options.wait_ms) or 1000
    local show_ui = options.show_ui ~= false
    local info
    local last_status_text

    local function setStatus(text)
        if not show_ui or text == last_status_text then
            return
        end
        if info then
            UIManager:close(info)
        end
        info = InfoMessage:new{text = text}
        last_status_text = text
        UIManager:show(info)
        UIManager:forceRePaint()
    end

    local function closeStatus()
        if info then
            UIManager:close(info)
            UIManager:forceRePaint()
            info = nil
        end
    end

    wcli, err = self:_newWpaClient()
    if not wcli then
        return false, T(CLIENT_INIT_ERR_MSG, err)
    end

    reply, err = wcli:addNetwork()
    if reply == nil then
        wcli:close()
        return false, err
    end
    local nw_id = reply

    reply, err = wcli:setNetwork(nw_id, "ssid", bin_to_hex(network.ssid))
    if reply == nil or reply == "FAIL" then
        wcli:removeNetwork(nw_id)
        wcli:close()
        return false, T("An error occurred while selecting network: %1.", err)
    end
    -- if password is empty it’s an open AP
    if network.password and #network.password == 0 then -- Open AP
        reply, err = wcli:setNetwork(nw_id, "key_mgmt", "NONE")
        if reply == nil or reply == "FAIL" then
            wcli:removeNetwork(nw_id)
            wcli:close()
            return false, T("An error occurred while setting passwordless mode: %1.", err)
        end
    -- else it’s a WPA AP
    else
        if not network.psk then
            network.psk = calculatePsk(network.ssid, network.password)
            self:saveNetwork(network)
        end
        reply, err = wcli:setNetwork(nw_id, "psk", network.psk)
        if reply == nil or reply == "FAIL" then
            wcli:removeNetwork(nw_id)
            wcli:close()
            return false, T("An error occurred while setting password: %1.", err)
        end
    end
    wcli:enableNetworkByID(nw_id)

    wcli:attach()
    local cnt = 0
    local failure_cnt = 0
    local success = false
    local msg = _("Authenticated")
    setStatus(_("Authenticating…"))
    while cnt < max_retry do
        -- Start by checking if we're not actually connected already...
        -- NOTE: This is mainly to catch corner-cases where our preferred network list differs from the system's,
        --       and ours happened to be sorted earlier because of a better signal quality...
        local connected, state = wcli:getConnectedNetwork()
        if connected then
            network.wpa_supplicant_id = connected.id
            network.ssid = decodeSSID(connected.ssid)
            success = true
            break
        else
            if state then
                -- Make the state prettier
                local first, rest = state:sub(1, 1), state:sub(2)
                setStatus(string.upper(first) .. string.lower(rest) .. "…")
            end
        end

        -- Otherwise, poke at the wpa_supplicant socket for a bit...
        local ev = wcli:readEvent()
        if ev ~= nil then
            if not ev:isScanEvent() then
                setStatus(ev.msg)
            end
            if ev:isAuthSuccessful() then
                network.wpa_supplicant_id = nw_id
                success = true
                break
            elseif ev:isAuthFailed() then
                failure_cnt = failure_cnt + 1
                if failure_cnt > 3 then
                    success, msg = false, _("Failed to authenticate")
                    break
                end
            end
        else
            wcli:waitForEvent(wait_ms)
            cnt = cnt + 1
        end
    end
    if success ~= true then
        wcli:removeNetwork(nw_id)
    end
    wcli:close()
    closeStatus()
    if cnt >= max_retry then
        success, msg = false, _("Timed out")
    end
    return success, msg
end

function WpaSupplicant:disconnectNetwork(network)
    if not network.wpa_supplicant_id then return end
    local wcli, err = self:_newWpaClient()
    if wcli == nil then
        return nil, T(CLIENT_INIT_ERR_MSG, err)
    end
    wcli:removeNetwork(network.wpa_supplicant_id)
    wcli:close()
end

function WpaSupplicant:getCurrentNetwork()
    local wcli, err = self:_newWpaClient()
    if wcli == nil then
        return nil, T(CLIENT_INIT_ERR_MSG, err)
    end

    -- Start by checking the status before looking for the CURRENT flag...
    local nw
    nw, err = wcli:getConnectedNetwork()
    logger.dbg("WpaSupplicant:getCurrentNetwork: Connected network:", nw and nw or err)
    -- Then fall back to the flag check...
    if nw == nil then
        nw, err = wcli:getCurrentNetwork()
        logger.dbg("WpaSupplicant:getCurrentNetwork: Current network:", nw and nw or err)
    end
    wcli:close()
    if nw ~= nil then
        nw.ssid = decodeSSID(nw.ssid)
    end
    return nw
end

function WpaSupplicant:getConfiguredNetworks()
    local wcli, err = self:_newWpaClient()
    if wcli == nil then
        return nil, T(CLIENT_INIT_ERR_MSG, err)
    end

    local nw
    nw, err = wcli:listNetworks()
    wcli:close()

    return nw, err
end

function WpaSupplicant.init(network_mgr, options)
    network_mgr.wpa_supplicant = {ctrl_interface = options.ctrl_interface}
    network_mgr._resolveCtrlInterface = WpaSupplicant._resolveCtrlInterface
    network_mgr._newWpaClient = WpaSupplicant._newWpaClient
    network_mgr.getConfiguredNetworks = WpaSupplicant.getConfiguredNetworks
    network_mgr.getNetworkList = WpaSupplicant.getNetworkList
    network_mgr.getCurrentNetwork = WpaSupplicant.getCurrentNetwork
    network_mgr.authenticateNetwork = WpaSupplicant.authenticateNetwork
    network_mgr.disconnectNetwork = WpaSupplicant.disconnectNetwork
end

return WpaSupplicant
