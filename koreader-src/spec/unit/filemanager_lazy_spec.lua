describe("FileManager lazy startup imports", function()
    local modules = {
        "apps/filemanager/filemanager",
        "apps/filemanager/filemanagermenu",
    }
    local lazy_modules = {
        "apps/reader/modules/readerdevicestatus",
        "apps/filemanager/filemanagerconverter",
        "apps/filemanager/filemanagersetdefaults",
        "languagesupport",
        "readcollection",
        "readhistory",
        "ui/network/networklistener",
        "ui/widget/buttondialog",
        "ui/widget/checkbutton",
        "ui/widget/doublespinwidget",
        "ui/widget/imageviewer",
        "ui/widget/infomessage",
        "ui/widget/inputdialog",
        "ui/widget/keyvaluepage",
        "ui/widget/multiconfirmbox",
        "ui/widget/screenshoter",
        "ui/widget/spinwidget",
        "ui/widget/textviewer",
    }

    setup(function()
        require("commonrequire")
    end)

    teardown(function()
        for _, name in ipairs(modules) do
            package.loaded[name] = nil
        end
        for _, name in ipairs(lazy_modules) do
            package.loaded[name] = nil
        end
    end)

    it("does not load secondary file dialogs just by loading the file manager", function()
        for _, name in ipairs(modules) do
            package.loaded[name] = nil
        end
        for _, name in ipairs(lazy_modules) do
            package.loaded[name] = nil
        end

        require("apps/filemanager/filemanager")

        for _, name in ipairs(lazy_modules) do
            assert.is_nil(package.loaded[name], name)
        end
    end)
end)
