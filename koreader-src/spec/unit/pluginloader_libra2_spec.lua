describe("PluginLoader Libra 2 startup profile", function()
    require("commonrequire")

    local PluginLoader

    setup(function()
        PluginLoader = require("pluginloader")
    end)

    before_each(function()
        disable_plugins()
        PluginLoader.all_plugins = nil
        G_reader_settings:saveSetting("libra2_lazy_disabled_plugin_meta", true)
    end)

    after_each(function()
        disable_plugins()
        PluginLoader.all_plugins = nil
        G_reader_settings:delSetting("libra2_lazy_disabled_plugin_meta")
        G_reader_settings:delSetting("plugins_disabled")
    end)

    it("skips disabled plugin metadata during startup load", function()
        local original_dofile = dofile
        local loaded_statistics_meta = false

        _G.dofile = function(path)
            if path == "plugins/statistics.koplugin/_meta.lua" then
                loaded_statistics_meta = true
                error("disabled plugin metadata should be lazy")
            end
            return original_dofile(path)
        end

        local ok, err = pcall(function()
            PluginLoader:_load{{
                main = "plugins/statistics.koplugin/_meta.lua",
                meta = "plugins/statistics.koplugin/_meta.lua",
                path = "plugins/statistics.koplugin",
                disabled = true,
                name = "statistics.koplugin",
                id = "statistics",
            }}
        end)
        _G.dofile = original_dofile

        assert.is_true(ok, err)
        assert.is_false(loaded_statistics_meta)
        assert.are.equal(1, #PluginLoader.disabled_plugins)
        assert.are.equal("statistics", PluginLoader.disabled_plugins[1].name)
        assert.are.equal("statistics", PluginLoader.disabled_plugins[1].fullname)
        assert.are.equal("plugins/statistics.koplugin/_meta.lua",
            PluginLoader.disabled_plugins[1]._metadata_pending)
    end)

    it("loads disabled plugin metadata only when the manager submenu is opened", function()
        PluginLoader.enabled_plugins = {}
        PluginLoader.disabled_plugins = {{
            path = "plugins/statistics.koplugin",
            name = "statistics",
            fullname = "statistics",
            description = "",
            _metadata_pending = "plugins/statistics.koplugin/_meta.lua",
        }}
        PluginLoader.loaded_plugins = {}

        local items = PluginLoader:genPluginManagerSubItem()

        assert.are.equal(1, #items)
        assert.are.equal("Reading statistics", items[1].text)
        assert.is_nil(PluginLoader.disabled_plugins[1]._metadata_pending)
        assert.are.equal("Keeps and displays your reading statistics.", items[1].help_text)
    end)
end)
