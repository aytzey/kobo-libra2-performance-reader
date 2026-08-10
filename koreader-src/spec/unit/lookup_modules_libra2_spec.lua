describe("Libra 2 lookup module startup", function()
    require("commonrequire")

    local function unloadLookupModules()
        package.unload("apps/reader/readerui")
        package.unload("apps/filemanager/filemanager")
        package.unload("apps/filemanager/filemanagercollection")
        package.unload("apps/filemanager/filemanagerfilesearcher")
        package.unload("apps/filemanager/filemanagerhistory")
        package.unload("apps/filemanager/filemanagershortcuts")
        package.unload("apps/reader/modules/readeractivityindicator")
        package.unload("apps/reader/modules/readerconfig")
        package.unload("apps/reader/modules/readercoptlistener")
        package.unload("apps/reader/modules/readercropping")
        package.unload("apps/reader/modules/readerdevicestatus")
        package.unload("apps/reader/modules/readerdictionary")
        package.unload("apps/reader/modules/readerfont")
        package.unload("apps/reader/modules/readerhighlight")
        package.unload("apps/reader/modules/readerhinting")
        package.unload("apps/reader/modules/readerkoptlistener")
        package.unload("apps/reader/modules/readerpagemap")
        package.unload("apps/reader/modules/readerpanning")
        package.unload("apps/reader/modules/readerpaging")
        package.unload("apps/reader/modules/readerrolling")
        package.unload("apps/reader/modules/readersearch")
        package.unload("apps/reader/modules/readerstyletweak")
        package.unload("apps/reader/modules/readertypeset")
        package.unload("apps/reader/modules/readertypography")
        package.unload("apps/reader/modules/readeruserhyph")
        package.unload("apps/reader/modules/readerwikipedia")
        package.unload("apps/reader/modules/readerzooming")
        package.unload("languagesupport")
        package.unload("ui/network/networklistener")
        package.unload("ui/widget/screenshoter")
        package.unload("ui/translator")
    end

    setup(function()
        disable_plugins()
        require("document/canvascontext"):init(require("device"))
    end)

    before_each(function()
        G_reader_settings:saveSetting("libra2_disable_lookup_modules", true)
        G_reader_settings:saveSetting("disable_highlight_lookup_actions", true)
        G_reader_settings:saveSetting("libra2_lazy_reader_sidepanels", true)
        G_reader_settings:saveSetting("libra2_disable_reader_screenshot_module", true)
        G_reader_settings:saveSetting("libra2_disable_reader_devicestatus_module", true)
        G_reader_settings:saveSetting("libra2_disable_reader_networklistener", true)
        unloadLookupModules()
    end)

    after_each(function()
        G_reader_settings:delSetting("libra2_disable_lookup_modules")
        G_reader_settings:delSetting("disable_highlight_lookup_actions")
        G_reader_settings:delSetting("libra2_lazy_reader_sidepanels")
        G_reader_settings:delSetting("libra2_disable_reader_screenshot_module")
        G_reader_settings:delSetting("libra2_disable_reader_devicestatus_module")
        G_reader_settings:delSetting("libra2_disable_reader_networklistener")
        unloadLookupModules()
    end)

    it("does not require hidden reader modules while loading ReaderUI", function()
        require("apps/reader/readerui")

        assert.is_nil(package.loaded["apps/reader/modules/readerdictionary"])
        assert.is_nil(package.loaded["apps/reader/modules/readerwikipedia"])
        assert.is_nil(package.loaded["apps/filemanager/filemanagercollection"])
        assert.is_nil(package.loaded["apps/filemanager/filemanagerfilesearcher"])
        assert.is_nil(package.loaded["apps/filemanager/filemanagerhistory"])
        assert.is_nil(package.loaded["apps/filemanager/filemanagershortcuts"])
        assert.is_nil(package.loaded["apps/reader/modules/readerdevicestatus"])
        assert.is_nil(package.loaded["ui/network/networklistener"])
        assert.is_nil(package.loaded["ui/widget/screenshoter"])

        for _, module_name in ipairs({
            "readeractivityindicator",
            "readerconfig",
            "readercoptlistener",
            "readercropping",
            "readerfont",
            "readerhinting",
            "readerkoptlistener",
            "readerpagemap",
            "readerpanning",
            "readerpaging",
            "readerrolling",
            "readersearch",
            "readerstyletweak",
            "readertypeset",
            "readertypography",
            "readeruserhyph",
            "readerzooming",
        }) do
            assert.is_nil(package.loaded["apps/reader/modules/" .. module_name], module_name)
        end
        assert.is_nil(package.loaded["languagesupport"])
    end)

    it("keeps reader history and collections unloaded until their menu entries are opened", function()
        local DocumentRegistry = require("document/documentregistry")
        local ReaderUI = require("apps/reader/readerui")
        unloadLookupModules()

        local readerui = ReaderUI:new{
            dimen = require("device").screen:getSize(),
            document = DocumentRegistry:openDocument("spec/front/unit/data/juliet.epub"),
        }
        local menu_items = {}

        assert.is_nil(package.loaded["apps/filemanager/filemanagerhistory"])
        assert.is_nil(package.loaded["apps/filemanager/filemanagercollection"])
        assert.is_function(readerui.history.onShowHist)
        assert.is_function(readerui.collections.onShowCollList)

        readerui.history:addToMainMenu(menu_items)
        readerui.collections:addToMainMenu(menu_items)
        assert.is_function(menu_items.history.callback)
        assert.is_function(menu_items.favorites.callback)
        assert.is_function(menu_items.collections.callback)
        assert.is_function(menu_items.bookmark_browser.callback)
        assert.is_nil(package.loaded["apps/filemanager/filemanagerhistory"])
        assert.is_nil(package.loaded["apps/filemanager/filemanagercollection"])

        readerui:closeDocument()
        ReaderUI.instance = nil
    end)

    it("does not require dictionary or Wikipedia while loading FileManager", function()
        require("apps/filemanager/filemanager")

        assert.is_nil(package.loaded["apps/reader/modules/readerdictionary"])
        assert.is_nil(package.loaded["apps/reader/modules/readerwikipedia"])
    end)

    it("does not require Translator while loading ReaderHighlight", function()
        require("apps/reader/modules/readerhighlight")

        assert.is_nil(package.loaded["ui/translator"])
    end)
end)
