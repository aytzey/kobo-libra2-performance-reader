describe("network_manager module", function()
    local Device
    local turn_on_wifi_called
    local turn_off_wifi_called
    local obtain_ip_called
    local release_ip_called
    local UIManager

    local function clearState()
        G_reader_settings:saveSetting("auto_restore_wifi", true)
        turn_on_wifi_called = 0
        turn_off_wifi_called = 0
        obtain_ip_called = 0
        release_ip_called = 0
    end

    setup(function()
        require("commonrequire")
        Device = require("device")
        UIManager = require("ui/uimanager")
        function Device:initNetworkManager(NetworkMgr)
            function NetworkMgr:turnOnWifi(callback)
                turn_on_wifi_called = turn_on_wifi_called + 1
                if callback then
                    callback()
                end
            end
            function NetworkMgr:turnOffWifi(callback)
                turn_off_wifi_called = turn_off_wifi_called + 1
                if callback then
                    callback()
                end
            end
            function NetworkMgr:obtainIP(callback)
                obtain_ip_called = obtain_ip_called + 1
                if callback then
                    callback()
                end
            end
            function NetworkMgr:releaseIP(callback)
                release_ip_called = release_ip_called + 1
                if callback then
                    callback()
                end
            end
            function NetworkMgr:restoreWifiAsync()
                self:turnOnWifi()
                self:obtainIP()
            end
        end
        function Device:hasWifiRestore()
            return true
        end
    end)

    it("should restore wifi in init if wifi was on", function()
        package.loaded["ui/network/manager"] = nil
        clearState()
        G_reader_settings:saveSetting("wifi_was_on", true)
        local network_manager = require("ui/network/manager") --luacheck: ignore
        assert.is.same(turn_on_wifi_called, 1)
        assert.is.same(turn_off_wifi_called, 0)
        assert.is.same(obtain_ip_called, 1)
        assert.is.same(release_ip_called, 0)
    end)

    it("should not restore wifi in init if wifi was off", function()
        package.loaded["ui/network/manager"] = nil
        clearState()
        G_reader_settings:saveSetting("wifi_was_on", false)
        local network_manager = require("ui/network/manager") --luacheck: ignore
        assert.is.same(turn_on_wifi_called, 0)
        assert.is.same(turn_off_wifi_called, 0)
        assert.is.same(obtain_ip_called, 0)
        assert.is.same(release_ip_called, 0)
    end)

    it("should prefer the last connected saved network", function()
        package.loaded["ui/network/manager"] = nil
        clearState()
        G_reader_settings:saveSetting("wifi_was_on", false)
        local LuaSettings = require("luasettings")
        local network_manager = require("ui/network/manager")

        network_manager.nw_settings = LuaSettings:wrap({
            Home = { password = "home-pass", flags = "[WPA2-PSK-CCMP][ESS]" },
            Office = { password = "office-pass", flags = "[WPA2-PSK-CCMP][ESS]" },
            __last_connected_ssid = "Office",
        })

        local candidates = network_manager:getSavedNetworkCandidates()
        assert.are.equal("Office", candidates[1].ssid)
    end)

    it("should fast reconnect to a saved network without scanning", function()
        package.loaded["ui/network/manager"] = nil
        clearState()
        G_reader_settings:saveSetting("wifi_was_on", false)
        local LuaSettings = require("luasettings")
        local network_manager = require("ui/network/manager")
        local scan_called = 0
        local auth_options

        network_manager.nw_settings = LuaSettings:wrap({})
        function network_manager:getCurrentNetwork()
            return nil
        end
        function network_manager:getSavedNetworkCandidates()
            return {
                { ssid = "Home", password = "home-pass", flags = "[WPA2-PSK-CCMP][ESS]" },
            }
        end
        function network_manager:authenticateNetwork(_, options)
            auth_options = options
            return true
        end
        function network_manager:getNetworkList()
            scan_called = scan_called + 1
            return {}
        end
        function network_manager:queryNetworkState()
            self.is_wifi_on = true
            self.is_connected = true
        end
        function Device:hasWifiManager()
            return true
        end

        local ok, ssid = network_manager:fastReconnectToSavedNetwork()
        assert.is_true(ok)
        assert.are.equal("Home", ssid)
        assert.are.equal(0, obtain_ip_called)
        assert.are.equal(0, scan_called)
        assert.is_false(auth_options.show_ui)
    end)

    it("should obtain IP asynchronously while waiting for a preferred network", function()
        package.loaded["ui/network/manager"] = nil
        clearState()
        G_reader_settings:saveSetting("wifi_was_on", false)
        local network_manager = require("ui/network/manager")
        local async_obtain_called = 0
        local query_count = 0
        local callback_called = false

        stub(UIManager, "scheduleIn")
        stub(UIManager, "show")
        UIManager.scheduleIn.invokes(function(_, _, callback)
            callback()
        end)

        function network_manager:getCurrentNetwork()
            return { ssid = "Home" }
        end
        function network_manager:startObtainIPAsync()
            async_obtain_called = async_obtain_called + 1
            return true
        end
        function network_manager:queryNetworkState()
            query_count = query_count + 1
            self.is_wifi_on = true
            self.is_connected = query_count >= 2
        end

        network_manager:startPreferredNetworkWait(function()
            callback_called = true
        end)

        assert.are.equal(1, async_obtain_called)
        assert.are.equal(0, obtain_ip_called)
        assert.is_true(callback_called)
    end)

    it("should clear pending connection when preferred network wait falls back", function()
        package.loaded["ui/network/manager"] = nil
        clearState()
        G_reader_settings:saveSetting("wifi_was_on", false)
        local network_manager = require("ui/network/manager")
        local fallback_called = false

        stub(UIManager, "scheduleIn")
        UIManager.scheduleIn.invokes(function(_, _, callback)
            callback()
        end)

        function network_manager:getCurrentNetwork()
            return nil
        end

        network_manager.pending_connection = true
        network_manager:startPreferredNetworkWait(nil, nil, function()
            fallback_called = true
        end)

        assert.is_true(fallback_called)
        assert.is_false(network_manager.pending_connection)
    end)

    it("keeps wpa_supplicant control on Wi-Fi sockets when USB networking is active", function()
        local file = assert(io.open("frontend/ui/network/wpa_supplicant.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find('local DEFAULT_WIFI_CTRL_INTERFACE = CTRL_INTERFACE_DIR .. "/wlan0"', 1, true))
        assert.truthy(source:find('ctrl_interface:match("/eth%d+$") ~= nil', 1, true))
        assert.truthy(source:find('ctrl_interface:match("/usb%d+$") ~= nil', 1, true))
        assert.truthy(source:find("function WpaSupplicant:_resolveCtrlInterface(force_probe)", 1, true))
        assert.truthy(source:find("self.wpa_supplicant.ctrl_interface = candidate", 1, true))
        assert.truthy(source:find("function WpaSupplicant:_newWpaClient()", 1, true))
        assert.truthy(source:find("local wcli, err = self:_newWpaClient()", 1, true))
        assert.is_nil(source:find("WpaClient.new(self.wpa_supplicant.ctrl_interface)", 1, true))
    end)

    after_each(function()
        if type(UIManager.scheduleIn) == "table" and UIManager.scheduleIn.revert then
            UIManager.scheduleIn:revert()
        end
        if type(UIManager.show) == "table" and UIManager.show.revert then
            UIManager.show:revert()
        end
    end)

    teardown(function()
        function Device:initNetworkManager() end
        function Device:hasWifiRestore() return false end
        function Device:hasWifiManager() return false end
        package.loaded["ui/network/manager"] = nil
    end)
end)
