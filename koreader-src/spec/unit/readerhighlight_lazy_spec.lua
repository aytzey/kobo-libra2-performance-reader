describe("ReaderHighlight lazy startup imports", function()
    local module_name = "apps/reader/modules/readerhighlight"
    local lazy_modules = {
        "ui/widget/buttondialog",
        "ui/widget/confirmbox",
        "ui/widget/doublespinwidget",
        "ui/widget/infomessage",
        "ui/widget/notification",
        "ui/widget/spinwidget",
        "ui/widget/textviewer",
    }

    setup(function()
        require("commonrequire")
    end)

    teardown(function()
        package.loaded[module_name] = nil
        for _, name in ipairs(lazy_modules) do
            package.loaded[name] = nil
        end
    end)

    it("does not load dialog widgets just by loading the highlight module", function()
        package.loaded[module_name] = nil
        for _, name in ipairs(lazy_modules) do
            package.loaded[name] = nil
        end

        require(module_name)

        for _, name in ipairs(lazy_modules) do
            assert.is_nil(package.loaded[name], name)
        end
    end)
end)
