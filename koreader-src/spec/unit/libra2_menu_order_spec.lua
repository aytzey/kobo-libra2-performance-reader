describe("Libra 2 menu order", function()
    local function contains(list, value)
        for _, item in ipairs(list) do
            if item == value then
                return true
            end
        end
        return false
    end

    local function assert_contains(list, value)
        assert.is_true(contains(list, value), value)
    end

    local function assert_not_contains(list, value)
        assert.is_false(contains(list, value), value)
    end

    local function find_by_id(items, id)
        for _, item in ipairs(items) do
            if item.id == id then
                return item
            end
            local child = item.sub_item_table or item
            if type(child) == "table" then
                local found = find_by_id(child, id)
                if found then
                    return found
                end
            end
        end
    end

    setup(function()
        require("commonrequire")
    end)

    it("keeps the reader top bar focused on reading tasks", function()
        local order = dofile("frontend/ui/elements/reader_menu_order.lua")
        local top = order["KOMenu:menu_buttons"]

        assert.is_same({
            "navi",
            "typeset",
            "main",
        }, top)
        assert_not_contains(top, "search")
        assert_not_contains(top, "tools")
        assert_not_contains(top, "filemanager")
        assert.is_nil(order.filemanager)
        assert_contains(order.main, "filemanager")
        assert_contains(order.main, "search")
        assert_contains(order.main, "setting")
        assert_contains(order.main, "more_tools")
        assert_not_contains(order.main, "tools")
        assert_not_contains(order.main, "favorites")
        assert_not_contains(order.main, "collections")
        assert_not_contains(order.main, "book_info")
        assert_contains(order.more_tools, "favorites")
        assert_contains(order.more_tools, "collections")
        assert_contains(order.more_tools, "book_info")
        assert_contains(order.more_tools, "help")
        assert_contains(order.more_tools, "plugin_management")
        assert_contains(order["KOMenu:disabled"], "tools")
        assert_contains(order["KOMenu:disabled"], "dictionary_lookup")
        assert_contains(order["KOMenu:disabled"], "wikipedia_lookup")
        assert_contains(order["KOMenu:disabled"], "translate_current_page")
    end)

    it("keeps hidden reader tools from leaking back as orphaned rows", function()
        local MenuSorter = require("ui/menusorter")
        local order = dofile("frontend/ui/elements/reader_menu_order.lua")
        local opened_filemanager = false
        local sorted = MenuSorter:sort({
            ["KOMenu:menu_buttons"] = {},
            navi = { text = "Navigation" },
            typeset = { text = "Format" },
            setting = { text = "Settings" },
            main = { text = "Main" },
            tools = { icon = "appbar.tools" },
            search = { text = "Search" },
            more_tools = { text = "More tools" },
            open_previous_document = { text = "Previous" },
            filemanager = {
                text = "File browser",
                callback = function()
                    opened_filemanager = true
                end,
            },
            history = { text = "History" },
            favorites = { text = "Favorites" },
            exit_menu = { text = "Exit" },
        }, order)

        assert.is_nil(find_by_id(sorted, "tools"))
        local settings = find_by_id(sorted, "setting")
        assert.is_not_nil(settings)
        assert.are.equal("Settings", settings.text)
        assert.is_table(settings.sub_item_table)
        local filemanager = find_by_id(sorted, "filemanager")
        assert.is_not_nil(filemanager)
        assert.is_function(filemanager.callback)
        assert.is_nil(filemanager.sub_item_table)
        filemanager.callback()
        assert.is_true(opened_filemanager)
    end)

    it("keeps the file manager top bar focused on browsing books", function()
        local order = dofile("frontend/ui/elements/filemanager_menu_order.lua")
        local top = order["KOMenu:menu_buttons"]

        assert.is_same({
            "filemanager_settings",
            "setting",
            "main",
            "plus_menu",
        }, top)
        assert_not_contains(top, "search")
        assert_not_contains(top, "tools")
        assert_contains(order.main, "search")
        assert_contains(order.main, "more_tools")
        assert_not_contains(order.main, "tools")
        assert_not_contains(order.main, "favorites")
        assert_not_contains(order.main, "collections")
        assert_contains(order.more_tools, "favorites")
        assert_contains(order.more_tools, "collections")
        assert_contains(order.more_tools, "help")
        assert_contains(order.more_tools, "plugin_management")
        assert_contains(order.more_tools, "advanced_settings")
        assert_contains(order["KOMenu:disabled"], "tools")
        assert_contains(order["KOMenu:disabled"], "dictionary_lookup")
        assert_contains(order["KOMenu:disabled"], "wikipedia_lookup")
    end)
end)
