describe("FileChooser Libra 2 fast sorting", function()
    local DataStorage, FileChooser, lfs

    local function makeChooser()
        return setmetatable({
            name = "filemanager",
            file_filter = function() return true end,
        }, { __index = FileChooser })
    end

    local function makeScanFixture()
        local dir = DataStorage:getDataDir() .. "/filechooser-libra2-scan"
        lfs.mkdir(dir)
        lfs.mkdir(dir .. "/Series")
        lfs.mkdir(dir .. "/Book.sdr")
        local file = assert(io.open(dir .. "/Book.epub", "w"))
        file:write("fixture")
        file:close()
        local metadata = assert(io.open(dir .. "/metadata.calibre", "w"))
        metadata:write("fixture")
        metadata:close()
        return dir
    end

    local function cleanupScanFixture(dir)
        os.remove(dir .. "/metadata.calibre")
        os.remove(dir .. "/Book.epub")
        lfs.rmdir(dir .. "/Book.sdr")
        lfs.rmdir(dir .. "/Series")
        lfs.rmdir(dir)
    end

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        FileChooser = require("ui/widget/filechooser")
        lfs = require("libs/libkoreader-lfs")
    end)

    teardown(function()
        G_reader_settings:delSetting("libra2_fast_filemanager_sort")
        G_reader_settings:delSetting("libra2_fast_filemanager_scan")
        G_reader_settings:delSetting("libra2_minimal_filemanager_details")
        G_reader_settings:delSetting("show_file_in_bold")
        FileChooser.show_hidden = G_reader_settings:readSetting("show_hidden", false)
    end)

    it("keeps stock sorting untouched when disabled", function()
        G_reader_settings:delSetting("libra2_fast_filemanager_sort")
        local items = {
            { text = "bravo" },
            { text = "Alpha" },
        }

        local sorting = FileChooser:getSortingFunction(FileChooser.collates.strcoll, false, "strcoll")
        table.sort(items, sorting)

        assert.is_nil(items[1].libra2_sort_key)
        assert.is_nil(items[2].libra2_sort_key)
    end)

    it("caches lowercase sort keys for the Libra 2 profile", function()
        G_reader_settings:saveSetting("libra2_fast_filemanager_sort", true)
        local items = {
            { text = "bravo" },
            { text = "Alpha" },
            { text = "alpha" },
        }

        local sorting = FileChooser:getSortingFunction(FileChooser.collates.strcoll, false, "strcoll")
        table.sort(items, sorting)

        assert.are.equal("Alpha", items[1].text)
        assert.are.equal("alpha", items[2].text)
        assert.are.equal("bravo", items[3].text)
        assert.are.equal("alpha", items[1].libra2_sort_key)
        assert.are.equal("alpha", items[2].libra2_sort_key)
        assert.are.equal("bravo", items[3].libra2_sort_key)
    end)

    it("keeps reverse sorting compatible with cached keys", function()
        G_reader_settings:saveSetting("libra2_fast_filemanager_sort", true)
        local items = {
            { text = "bravo" },
            { text = "Alpha" },
        }

        local sorting = FileChooser:getSortingFunction(FileChooser.collates.strcoll, true, "strcoll")
        table.sort(items, sorting)

        assert.are.equal("bravo", items[1].text)
        assert.are.equal("Alpha", items[2].text)
    end)

    it("reuses the active collate while building a path item table", function()
        local dir = makeScanFixture()
        local old_get_collate = FileChooser.getCollate
        local calls = 0
        FileChooser.getCollate = function(self)
            calls = calls + 1
            return old_get_collate(self)
        end

        makeChooser():genItemTableFromPath(dir)

        FileChooser.getCollate = old_get_collate
        cleanupScanFixture(dir)
        assert.are.equal(1, calls)
    end)

    it("uses mode-only stat and suppresses secondary details for the Libra 2 profile", function()
        G_reader_settings:saveSetting("libra2_fast_filemanager_scan", true)
        G_reader_settings:saveSetting("libra2_minimal_filemanager_details", true)
        G_reader_settings:saveSetting("show_file_in_bold", false)
        local dir = makeScanFixture()
        local old_attributes = lfs.attributes
        local calls = {}
        lfs.attributes = function(path, key)
            table.insert(calls, { path = path, key = key or "full" })
            return old_attributes(path, key)
        end

        local dirs, files = makeChooser():getList(dir, FileChooser.collates.strcoll)

        lfs.attributes = old_attributes
        cleanupScanFixture(dir)
        assert.are.equal(1, #dirs)
        assert.are.equal(1, #files)
        assert.are.equal("directory", dirs[1].attr.mode)
        assert.are.equal("file", files[1].attr.mode)
        assert.is_nil(files[1].attr.size)
        assert.is_nil(dirs[1].mandatory)
        assert.is_nil(files[1].mandatory)
        for _, call in ipairs(calls) do
            assert.are.equal("mode", call.key)
            assert.is_nil(call.path:match("Book%.sdr$"))
            assert.is_nil(call.path:match("metadata%.calibre$"))
        end
    end)

    it("skips hidden and known sidecar names before stat in the Libra 2 scan path", function()
        G_reader_settings:saveSetting("libra2_fast_filemanager_scan", true)
        G_reader_settings:saveSetting("libra2_minimal_filemanager_details", true)
        G_reader_settings:saveSetting("show_file_in_bold", false)
        FileChooser.show_hidden = false
        local dir = makeScanFixture()
        local hidden = assert(io.open(dir .. "/.hidden.epub", "w"))
        hidden:write("fixture")
        hidden:close()
        local old_attributes = lfs.attributes
        local paths = {}
        lfs.attributes = function(path, key)
            paths[path] = key or "full"
            return old_attributes(path, key)
        end

        local dirs, files = makeChooser():getList(dir, FileChooser.collates.strcoll)

        lfs.attributes = old_attributes
        os.remove(dir .. "/.hidden.epub")
        cleanupScanFixture(dir)
        assert.are.equal(1, #dirs)
        assert.are.equal(1, #files)
        assert.is_nil(paths[dir .. "/.hidden.epub"])
        assert.is_nil(paths[dir .. "/Book.sdr"])
        assert.is_nil(paths[dir .. "/metadata.calibre"])
    end)

    it("keeps full stat path when the scan fast path is disabled", function()
        G_reader_settings:delSetting("libra2_fast_filemanager_scan")
        G_reader_settings:saveSetting("libra2_minimal_filemanager_details", true)
        G_reader_settings:saveSetting("show_file_in_bold", false)
        local dir = makeScanFixture()
        local old_attributes = lfs.attributes
        local saw_full_stat = false
        lfs.attributes = function(path, key)
            if key == nil then
                saw_full_stat = true
            end
            return old_attributes(path, key)
        end

        makeChooser():getList(dir, FileChooser.collates.strcoll)

        lfs.attributes = old_attributes
        cleanupScanFixture(dir)
        assert.is_true(saw_full_stat)
    end)
end)
