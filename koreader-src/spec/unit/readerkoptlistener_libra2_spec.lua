describe("ReaderKoptListener Libra 2 OCR startup path", function()
    local module_name = "apps/reader/modules/readerkoptlistener"
    local ocr_module_name = "ui/data/ocr"

    local function reloadListener()
        package.loaded[module_name] = nil
        package.loaded[ocr_module_name] = nil
        package.loaded["apps/reader/modules/readerzooming"] = nil
        return require(module_name)
    end

    local function settings()
        return {
            readSetting = function() return nil end,
        }
    end

    local function makeListener(ReaderKoptListener, ocr_enabled)
        local events = {}
        local listener = ReaderKoptListener:new{
            document = {
                configurable = {
                    text_wrap = 0,
                    contrast = 1,
                    word_spacing = 0,
                    doc_language = "eng",
                },
                koptinterface = {
                    isOCRFallbackEnabled = function()
                        return ocr_enabled
                    end,
                },
            },
            ui = {
                handleEvent = function(_, event)
                    table.insert(events, event.handler)
                end,
            },
        }
        return listener, events
    end

    teardown(function()
        package.loaded[module_name] = nil
        package.loaded[ocr_module_name] = nil
    end)

    setup(function()
        require("commonrequire")
    end)

    it("does not load OCR utilities when OCR fallback is disabled", function()
        local old_preload = package.preload[ocr_module_name]
        local ocr_loads = 0
        package.preload[ocr_module_name] = function()
            ocr_loads = ocr_loads + 1
            return {
                getOCRLangs = function()
                    return { "eng" }
                end,
            }
        end

        local ReaderKoptListener = reloadListener()
        assert.is_nil(package.loaded[ocr_module_name])
        local listener, events = makeListener(ReaderKoptListener, false)

        listener:onReadSettings(settings())

        package.preload[ocr_module_name] = old_preload
        assert.are.equal(0, ocr_loads)
        assert.is_nil(package.loaded[ocr_module_name])
        assert.is_false(table.concat(events, ","):find("onDocLangUpdate", 1, true) ~= nil)
    end)

    it("lazy-loads OCR utilities when OCR fallback is enabled", function()
        local old_preload = package.preload[ocr_module_name]
        local ocr_loads = 0
        package.preload[ocr_module_name] = function()
            ocr_loads = ocr_loads + 1
            return {
                getOCRLangs = function()
                    return { "tur" }
                end,
            }
        end

        local ReaderKoptListener = reloadListener()
        assert.is_nil(package.loaded[ocr_module_name])
        local listener, events = makeListener(ReaderKoptListener, true)

        listener:onReadSettings(settings())

        package.preload[ocr_module_name] = old_preload
        assert.are.equal(1, ocr_loads)
        assert.are.equal("tur", listener.document.configurable.doc_language)
        assert.is_true(table.concat(events, ","):find("onDocLangUpdate", 1, true) ~= nil)
    end)
end)
