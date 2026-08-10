describe("Koptinterface module", function()
    local DocumentRegistry, Koptinterface
    setup(function()
        require("commonrequire")
        DocumentRegistry = require("document/documentregistry")
        Koptinterface = require("document/koptinterface")
    end)

    describe("context hash", function()
        local function genericConfigHash(configurable)
            local hash_list = {}
            configurable:hash(hash_list)
            return table.concat(hash_list, "|")
        end

        local function fastConfigHash(configurable)
            local hash_list = {}
            Koptinterface._appendConfigurableHash(configurable, hash_list)
            return table.concat(hash_list, "|")
        end

        it("matches the legacy sorted configurable hash on the KOPT option set", function()
            local configurable = {
                text_wrap = 1,
                trim_page = 3,
                doc_language = "eng",
                font_size = 1.2,
                page_margin = 0.1,
                contrast = 1.5,
                zoom_mode_genus = 4,
                zoom_mode_type = 1,
                zoom_overlap_h = 36,
                zoom_overlap_v = 36,
                disable_ocr_fallback = 1,
                forced_ocr = 0,
                quality = 1.0,
                rotation_mode = 0,
                hw_dithering = 0,
                sw_dithering = 0,
                nightmode_document = 0,
            }
            setmetatable(configurable, { __index = require("configurable") })

            assert.are.equal(genericConfigHash(configurable), fastConfigHash(configurable))
        end)

        it("falls back to the legacy sorted hash when an unknown scalar key appears", function()
            local configurable = {
                text_wrap = 1,
                trim_page = 3,
                doc_language = "eng",
                future_kopt_scalar = 42,
            }
            setmetatable(configurable, { __index = require("configurable") })

            assert.are.equal(genericConfigHash(configurable), fastConfigHash(configurable))
        end)
    end)

    describe("background context wait interval", function()
        local function assertWaitInterval(setting_value, expected_sleep)
            local FFIUtil = require("ffi/util")
            local CanvasContext = require("document/canvascontext")
            local old_usleep = FFIUtil.usleep
            local old_enable_cpu_cores = CanvasContext.enableCPUCores
            local key = "DKOPTREADER_BACKGROUND_WAIT_US"
            local old_customized = G_defaults:hasBeenCustomized(key)
            local old_value = old_customized and G_defaults:readSetting(key)
            local sleeps = {}
            local cpu_cores = {}
            local calls = 0
            local kc = {
                isPreCache = function()
                    calls = calls + 1
                    return calls <= 2 and 1 or 0
                end,
            }

            if setting_value == nil then
                G_defaults:delSetting(key)
            else
                G_defaults:saveSetting(key, setting_value)
            end
            FFIUtil.usleep = function(interval)
                table.insert(sleeps, interval)
            end
            CanvasContext.enableCPUCores = function(_, cores)
                table.insert(cpu_cores, cores)
            end
            Koptinterface.bg_thread = true

            local ok, err = pcall(function()
                assert.are.equal(kc, Koptinterface:waitForContext(kc))
                assert.are.same({ expected_sleep, expected_sleep }, sleeps)
                assert.are.same({ 1 }, cpu_cores)
            end)

            if old_customized then
                G_defaults:saveSetting(key, old_value)
            else
                G_defaults:delSetting(key)
            end
            FFIUtil.usleep = old_usleep
            CanvasContext.enableCPUCores = old_enable_cpu_cores
            Koptinterface.bg_thread = nil

            if not ok then
                error(err)
            end
        end

        it("uses the configured polling interval", function()
            assertWaitInterval(25000, 25000)
        end)

        it("falls back to 100ms for missing or invalid settings", function()
            assertWaitInterval(nil, 100000)
            assertWaitInterval("invalid", 100000)
        end)

        it("clamps extremely low polling intervals", function()
            assertWaitInterval(10, 1000)
        end)
    end)

    describe("OCR fallback guard", function()
        local default_key = "DKOPTREADER_DISABLE_OCR_FALLBACK"
        local reader_key = "disable_ocr_fallback"

        local function withOCRFallbackDisabled(fn)
            local old_default_customized = G_defaults:hasBeenCustomized(default_key)
            local old_default_value = old_default_customized and G_defaults:readSetting(default_key)
            local old_reader_value = G_reader_settings:readSetting(reader_key)
            local had_reader_value = old_reader_value ~= nil

            G_defaults:saveSetting(default_key, false)
            G_reader_settings:saveSetting(reader_key, true)

            local ok, err = pcall(fn)

            if old_default_customized then
                G_defaults:saveSetting(default_key, old_default_value)
            else
                G_defaults:delSetting(default_key)
            end
            if had_reader_value then
                G_reader_settings:saveSetting(reader_key, old_reader_value)
            else
                G_reader_settings:delSetting(reader_key)
            end

            if not ok then
                error(err)
            end
        end

        it("keeps native text and skips forced OCR when disabled", function()
            withOCRFallbackDisabled(function()
                local calls = 0
                local old_scratch = Koptinterface.getNativeTextBoxesFromScratch
                Koptinterface.getNativeTextBoxesFromScratch = function()
                    calls = calls + 1
                    return { "ocr" }
                end

                local ok, err = pcall(function()
                    local native_boxes = { "native", "text" }
                    local doc = {
                        configurable = {
                            forced_ocr = 1,
                            text_wrap = 0,
                        },
                        getPageTextBoxes = function()
                            return native_boxes
                        end,
                    }

                    assert.are.same(native_boxes, Koptinterface:getTextBoxes(doc, 1))
                    assert.are.equal(0, calls)
                end)

                Koptinterface.getNativeTextBoxesFromScratch = old_scratch
                if not ok then error(err) end
            end)
        end)

        it("does not fall back to OCR when a page has no text layer", function()
            withOCRFallbackDisabled(function()
                local calls = 0
                local old_scratch = Koptinterface.getNativeTextBoxesFromScratch
                Koptinterface.getNativeTextBoxesFromScratch = function()
                    calls = calls + 1
                    return { "ocr" }
                end

                local ok, err = pcall(function()
                    local doc = {
                        configurable = {
                            forced_ocr = 0,
                            text_wrap = 0,
                        },
                        getPageTextBoxes = function()
                            return nil
                        end,
                    }

                    assert.is_nil(Koptinterface:getTextBoxes(doc, 1))
                    assert.are.equal(0, calls)
                    assert.is_nil(Koptinterface:getOCRWord(doc, 1, { sbox = { x = 0, y = 0, w = 10, h = 10 } }))
                end)

                Koptinterface.getNativeTextBoxesFromScratch = old_scratch
                if not ok then error(err) end
            end)
        end)
    end)

    describe("should", function()

        local doc

        setup(function()
            doc = DocumentRegistry:openDocument("spec/front/unit/data/tall.pdf")
            doc.configurable.text_wrap = 0
        end)

        teardown(function()
            doc:close()
        end)

        it("should get auto bbox", function()
            local auto_bbox = Koptinterface:getAutoBBox(doc, 1)
            assert.is.near(22, auto_bbox.x0, 0.5)
            assert.is.near(38, auto_bbox.y0, 0.5)
            assert.is.near(548, auto_bbox.x1, 0.5)
            assert.is.near(1387, auto_bbox.y1, 0.5)
        end)

        it("should get semi auto bbox", function()
            local semiauto_bbox = Koptinterface:getSemiAutoBBox(doc, 1)
            local page_bbox = doc:getPageBBox(1)
            doc.bbox[1] = {
                x0 = page_bbox.x0 + 10,
                y0 = page_bbox.y0 + 10,
                x1 = page_bbox.x1 - 10,
                y1 = page_bbox.y1 - 10,
            }

            local bbox = Koptinterface:getSemiAutoBBox(doc, 1)
            assert.is_not.near(semiauto_bbox.x0, bbox.x0, 0.5)
            assert.is_not.near(semiauto_bbox.y0, bbox.y0, 0.5)
            assert.is_not.near(semiauto_bbox.x1, bbox.x1, 0.5)
            assert.is_not.near(semiauto_bbox.y1, bbox.y1, 0.5)
        end)

        it("should render optimized page to de-watermark", function()
            local page_dimen = doc:getPageDimensions(1, 1.0, 0)
            local tile = Koptinterface:renderOptimizedPage(doc, 1, nil,
            1.0, 0, 0)
            assert.truthy(tile)
            assert.are.same(page_dimen, tile.excerpt)
        end)

        it("should reflow page in foreground", function()
            doc.configurable.text_wrap = 1
            local kc = Koptinterface:getCachedContext(doc, 1)
            assert.truthy(kc)
        end)

        it("should hint reflowed page in background", function()
            doc.configurable.text_wrap = 1
            Koptinterface:hintReflowedPage(doc, 1, 1.0, 0, 1.0, 0)
            -- and wait for reflowing to complete
            local kc = Koptinterface:getCachedContext(doc, 1)
            assert.truthy(kc)
        end)

        it("should get native text boxes", function()
            Koptinterface:getCachedContext(doc, 1)
            local boxes = Koptinterface:getNativeTextBoxes(doc, 1)
            assert.equal(60, #boxes)
        end)

        it("should get native text boxes from scratch", function()
            Koptinterface:getCachedContext(doc, 1)
            local boxes = Koptinterface:getNativeTextBoxesFromScratch(doc, 1)
            assert.equal(60, #boxes)
        end)

        it("should get reflow text boxes", function()
            doc.configurable.text_wrap = 1
            Koptinterface:getCachedContext(doc, 1)
            local boxes = Koptinterface:getReflowedTextBoxes(doc, 1)
            local lines_in_reflowed_page = #boxes
            assert.truthy(lines_in_reflowed_page > 60)
        end)

        it("should get reflow text boxes from scratch", function()
            doc.configurable.text_wrap = 1
            Koptinterface:getCachedContext(doc, 1)
            local boxes = Koptinterface:getReflowedTextBoxesFromScratch(doc, 1)
            local lines_in_reflowed_page = #boxes
            assert.truthy(lines_in_reflowed_page > 60)
        end)

    end)

    describe("should", function()

        local complex_doc

        setup(function()
            complex_doc = DocumentRegistry:openDocument("spec/front/unit/data/sample.pdf")
            complex_doc.configurable.text_wrap = 0
        end)

        teardown(function()
            complex_doc:close()
        end)

        it("should get page block of a two-column page", function()
            for i = 0.3, 0.6, 0.3 do
                for j = 0.3, 0.6, 0.3 do
                    local block = Koptinterface:getPageBlock(complex_doc, 34, i, j)
                    assert.truthy(block.x1 - block.x0 < 0.5)
                end
            end
        end)

        it("should get word from native position", function()
            local word_boxes = Koptinterface:getWordFromPosition(complex_doc, {
                page = 19, x = 400, y = 530,
            })
            assert.is.same("previous", word_boxes.word)
        end)

        it("should get word from reflow position", function()
            complex_doc.configurable.text_wrap = 1
            Koptinterface:getCachedContext(complex_doc, 19)
            local word_boxes = Koptinterface:getWordFromPosition(complex_doc, {
                page = 19, x = 320, y = 730,
            })
            assert.is.same("time,", word_boxes.word)
        end)

    end)

    describe("should", function()

        local paper_doc

        setup(function()
            paper_doc = DocumentRegistry:openDocument("spec/front/unit/data/paper.pdf")
            paper_doc.configurable.text_wrap = 0
        end)

        teardown(function()
            paper_doc:close()
        end)

        it("should get link from native position", function()
            local link = Koptinterface:getLinkFromPosition(paper_doc, 1, {
                x = 140, y = 560,
            })
            assert.truthy(link)
            assert.is.same(20, link.page)
            require("dbg"):v("link", link)
        end)

        it("should get link from reflow position", function()
            paper_doc.configurable.text_wrap = 1
            local link = Koptinterface:getLinkFromPosition(paper_doc, 1, {
                x = 455, y = 1105,
            })
            assert.truthy(link)
            assert.is.same(20, link.page)
        end)

    end)

end)
