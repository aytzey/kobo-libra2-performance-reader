describe("Dispatcher runtime actions", function()
    local Dispatcher
    local Screen
    local settingsList

    setup(function()
        require("commonrequire")
        Dispatcher = require("frontend/dispatcher")
        Screen = require("device").screen
        -- grab private settingsList from upvalue of registerAction
        local i = 1
        while true do
            local name, val = debug.getupvalue(Dispatcher.registerAction, i)
            if not name then break end
            if name == "settingsList" then
                settingsList = val
                break
            end
            i = i + 1
        end
        assert.is_truthy(settingsList)
    end)

    it("should add and remove a custom action", function()
        assert.is_nil(settingsList.custom_test)
        Dispatcher:registerAction("custom_test", {category="none", event="TestEvent"})
        assert.equals("TestEvent", settingsList.custom_test.event)
        -- registering again should not duplicate
        Dispatcher:registerAction("custom_test", {category="none", event="TestEvent"})
        -- remove it
        Dispatcher:removeAction("custom_test")
        assert.is_nil(settingsList.custom_test)
    end)

    it("removeAction on missing name does not error", function()
        assert.is_truthy(Dispatcher:removeAction("nopenopenope"))
    end)

    it("supports compact QuickMenu width factors with clamping", function()
        assert.equals(
            math.floor(0.46 * Screen:getWidth()),
            Dispatcher.getQuickMenuMinWidth({ settings = { quickmenu_min_width_factor = 0.46 } })
        )
        assert.equals(
            math.floor(0.35 * Screen:getWidth()),
            Dispatcher.getQuickMenuMinWidth({ settings = { quickmenu_min_width_factor = 0.1 } })
        )
        assert.equals(
            math.floor(0.9 * Screen:getWidth()),
            Dispatcher.getQuickMenuMinWidth({ settings = { quickmenu_min_width_factor = 1.2 } })
        )
        assert.equals(math.floor(0.6 * Screen:getWidth()), Dispatcher.getQuickMenuMinWidth())
    end)
end)
