describe("Readerhighlight module", function()
    local DataStorage, DocumentRegistry, ReaderHighlight, ReaderUI, UIManager, Screen, Geom, Event
    local sample_pdf

    setup(function()
        require("commonrequire")
        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        DataStorage = require("datastorage")
        DocumentRegistry = require("document/documentregistry")
        Event = require("ui/event")
        Geom = require("ui/geometry")
        ReaderHighlight = require("apps/reader/modules/readerhighlight")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        UIManager = require("ui/uimanager")
        load_plugin('japanese.koplugin')
        sample_pdf = DataStorage:getDataDir() .. "/readerhighlight.pdf"
        require("ffi/util").copyFile("spec/front/unit/data/sample.pdf", sample_pdf)
    end)

    local readerui

    local function highlight_single_word(screenshot_filename, pos0)
        local s = spy.on(readerui.languagesupport, "improveWordSelection")
        -- Select a word.
        readerui.highlight:onHold(nil, { pos = pos0 })
        readerui.highlight:onHoldRelease()
        readerui.highlight:saveHighlight()
        fastforward_ui_events()
        screenshot(Screen, screenshot_filename)
        assert.spy(s).was_called()
        assert.spy(s).was_called_with(match.is_ref(readerui.languagesupport),
                                      match.is_ref(readerui.highlight.selected_text))
        -- Reset in case we're called more than once.
        readerui.languagesupport.improveWordSelection:revert()
    end
    local function highlight_text(screenshot_filename, pos0, pos1)
        readerui.highlight:onHold(nil, { pos = pos0 })
        readerui.highlight:onHoldPan(nil, { pos = pos1 })
        local next_slot
        for i = #UIManager._window_stack, 0, -1 do
            local top_window = UIManager._window_stack[i]
            -- skip modal window
            if not top_window or not top_window.widget.modal then
                next_slot = i + 1
                break
            end
        end
        readerui.highlight:onHoldRelease()
        fastforward_ui_events()
        screenshot(Screen, screenshot_filename)
        assert.truthy(readerui.highlight.highlight_dialog)
        assert.truthy(UIManager._window_stack[next_slot].widget
                      == readerui.highlight.highlight_dialog)
        readerui.highlight:saveHighlight()
    end
    local function tap_highlight_text(screenshot_filename, pos0, pos1, pos2)
        -- Highlight some text.
        readerui.highlight:onHold(nil, { pos = pos0 })
        readerui.highlight:onHoldPan(nil, { pos = pos1 })
        readerui.highlight:onHoldRelease()
        readerui.highlight:saveHighlight()
        readerui.highlight:clear()
        -- Close dialog.
        UIManager:close(readerui.highlight.highlight_dialog)
        fastforward_ui_events()
        -- Tap it.
        readerui.highlight:onTap(nil, { pos = pos2 })
        fastforward_ui_events()
        screenshot(Screen, screenshot_filename)
        assert.truthy(UIManager:getTopmostVisibleWidget().name == "edit_highlight_dialog")
    end

    describe("lookup-free highlight profile", function()
        before_each(function()
            G_reader_settings:saveSetting("disable_highlight_lookup_actions", true)
            G_reader_settings:saveSetting("default_highlight_action", "ask")
            G_reader_settings:saveSetting("highlight_action_on_single_word", false)
        end)
        after_each(function()
            G_reader_settings:delSetting("disable_highlight_lookup_actions")
            G_reader_settings:delSetting("default_highlight_action")
            G_reader_settings:delSetting("highlight_action_on_single_word")
        end)
        it("removes lookup actions from dispatcher choices", function()
            local _, action_texts = ReaderHighlight:getHighlightActions()
            local joined = table.concat(action_texts, "\n")

            assert.is_nil(joined:find("Dictionary", 1, true))
            assert.is_nil(joined:find("Wikipedia", 1, true))
            assert.is_nil(joined:find("Translate", 1, true))
            assert.is_nil(joined:find("Fulltext search", 1, true))
            assert.truthy(joined:find("Select and highlight", 1, true))
        end)
        it("falls back to the filtered highlight menu when an old lookup action is requested", function()
            local highlight = { view = { highlight = {} } }

            assert.is_true(ReaderHighlight.onSetHighlightAction(highlight, 8, true)) -- Dictionary
            assert.are.equal("ask", G_reader_settings:readSetting("default_highlight_action"))
            assert.is_false(highlight.view.highlight.disabled)
        end)
        it("does not open dictionary on single-word release", function()
            local lookup_called = false
            local show_menu_called = false
            local highlight = {
                selected_text = { text = "thy" },
                is_word_selection = true,
                view = { highlight = {} },
                _resetHoldTimer = function() end,
                lookupDictWord = function()
                    lookup_called = true
                end,
                onShowHighlightMenu = function()
                    show_menu_called = true
                end,
            }

            assert.is_true(ReaderHighlight.onHoldRelease(highlight))
            assert.is_false(lookup_called)
            assert.is_true(show_menu_called)
            assert.is_false(highlight.is_word_selection)
        end)
    end)

    describe("OCR fallback guard", function()
        local function withOCRUnavailableMessageSpy(fn)
            local old_show = UIManager.show
            local show_calls = 0
            UIManager.show = function(_, widget)
                show_calls = show_calls + 1
                assert.truthy(widget.text:find("No OCR results", 1, true))
            end

            local ok, err = pcall(function()
                fn(function() return show_calls end)
            end)

            UIManager.show = old_show
            if not ok then error(err) end
        end

        local function makeScannedSelectionHighlight()
            local ocr_text_calls = 0
            local ocr_word_calls = 0
            local dictionary_calls = 0
            local translate_calls = 0
            local highlight = {
                selected_text = {
                    text = "",
                    sboxes = {
                        { x = 1, y = 2, w = 3, h = 4 },
                        { x = 5, y = 6, w = 7, h = 8 },
                    },
                },
                hold_pos = { page = 1 },
                view = {
                    pageToScreenTransform = function(_, _, box) return box end,
                },
                ui = {
                    document = {
                        configurable = {},
                        koptinterface = {
                            isOCRFallbackEnabled = function()
                                return false
                            end,
                        },
                        getOCRText = function()
                            ocr_text_calls = ocr_text_calls + 1
                            return "should-not-run"
                        end,
                        getOCRWord = function()
                            ocr_word_calls = ocr_word_calls + 1
                            return "should-not-run"
                        end,
                    },
                    dictionary = {
                        onLookupWord = function()
                            dictionary_calls = dictionary_calls + 1
                        end,
                    },
                },
                onTranslateText = function()
                    translate_calls = translate_calls + 1
                end,
                calls = function()
                    return ocr_text_calls, ocr_word_calls, dictionary_calls, translate_calls
                end,
            }
            return setmetatable(highlight, { __index = ReaderHighlight })
        end

        before_each(function()
            G_reader_settings:delSetting("disable_highlight_lookup_actions")
        end)

        it("skips dictionary OCR word fallback when OCR is disabled", function()
            withOCRUnavailableMessageSpy(function(show_calls)
                local highlight = makeScannedSelectionHighlight()

                ReaderHighlight.lookupDictWord(highlight)

                local ocr_text_calls, ocr_word_calls, dictionary_calls = highlight.calls()
                assert.are.equal(0, ocr_text_calls)
                assert.are.equal(0, ocr_word_calls)
                assert.are.equal(0, dictionary_calls)
                assert.are.equal(1, show_calls())
            end)
        end)

        it("skips translate OCR fallback when OCR is disabled", function()
            withOCRUnavailableMessageSpy(function(show_calls)
                local highlight = makeScannedSelectionHighlight()

                ReaderHighlight.translate(highlight)

                local ocr_text_calls, ocr_word_calls, _, translate_calls = highlight.calls()
                assert.are.equal(0, ocr_text_calls)
                assert.are.equal(0, ocr_word_calls)
                assert.are.equal(0, translate_calls)
                assert.are.equal(1, show_calls())
            end)
        end)
    end)

    describe("highlight for EPUB documents", function()
        local selection_spy
        setup(function()
            readerui = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument("spec/front/unit/data/juliet.epub"),
            }
            selection_spy = spy.on(readerui.languagesupport, "improveWordSelection")
        end)
        teardown(function()
            readerui:onClose()
        end)
        before_each(function()
            UIManager:show(readerui)
            readerui.rolling:onGotoPage(10)
        end)
        after_each(function()
            selection_spy:clear()
            readerui.highlight:clear()
            readerui.annotation.annotations = {}
            UIManager:quit()
        end)
        it("should highlight word", function()
            highlight_single_word("readerhighlight_epub_word.png",
                                  Geom:new{ x = 400, y = 70 })
            assert.spy(selection_spy).was_called()
            assert.Equals(1, #readerui.annotation.annotations)
            assert.Equals('thy', readerui.annotation.annotations[1].text)
        end)
        it("should highlight text", function()
            highlight_text("readerhighlight_epub_text.png",
                           Geom:new{ x = 400, y = 110 },
                           Geom:new{ x = 400, y = 170 })
            assert.spy(selection_spy).was_called()
            assert.Equals(1, #readerui.annotation.annotations)
            assert.Equals('Montagues.\nSAMPSON', readerui.annotation.annotations[1].text)
        end)
        it("should response on tap gesture", function()
            tap_highlight_text("readerhighlight_epub_tap.png",
                               Geom:new{ x = 106, y = 271 },
                               Geom:new{ x = 370, y = 314 },
                               Geom:new{ x = 190, y = 305 })
            assert.spy(selection_spy).was_called()
            assert.Equals('GREGORY\nHow! turn thy back and run?', readerui.annotation.annotations[1].text)
        end)
    end)

    describe("highlight for PDF documents in page mode", function()
        setup(function()
            readerui = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument(sample_pdf),
                _testsuite = true,
            }
            readerui.hinting.view.hinting = false
            readerui:handleEvent(Event:new("SetScrollMode", false))
        end)
        teardown(function()
            readerui:onClose()
        end)
        before_each(function()
            UIManager:show(readerui)
        end)
        after_each(function()
            readerui.highlight:clear()
            readerui.annotation.annotations = {}
            UIManager:quit()
        end)
        describe("for scanned page with text layer", function()
            before_each(function()
                readerui.paging:onGotoPage(10)
            end)
            it("should highlight word", function()
                highlight_single_word("readerhighlight_pdf_layer_word.png",
                                      Geom:new{ x = 260, y = 70 })
                assert.Equals(1, #readerui.annotation.annotations)
                assert.Equals('Penn', readerui.annotation.annotations[1].text)
            end)
            it("should highlight text", function()
                highlight_text("readerhighlight_pdf_layer_text.png",
                               Geom:new{ x = 430, y = 210 },
                               Geom:new{ x = 60, y = 236 })
                assert.Equals(1, #readerui.annotation.annotations)
                assert.Equals('to take care of the London', readerui.annotation.annotations[1].text)
            end)
            it("should response on tap gesture", function()
                tap_highlight_text("readerhighlight_pdf_layer_tap.png",
                                   Geom:new{ x = 260, y = 70 },
                                   Geom:new{ x = 260, y = 150 },
                                   Geom:new{ x = 280, y = 110 })
            end)
        end)
        describe("for scanned page without text layer", function()
            before_each(function()
                readerui.paging:onGotoPage(28)
            end)
            it("should highlight word", function()
                highlight_single_word("readerhighlight_pdf_ocr_word.png",
                                      Geom:new{ x = 450, y = 60 })
                assert.Equals(1, #readerui.annotation.annotations)
                --- @fixme: OCR should automatically kicks in.
                -- assert.Equals('synthesis', readerui.annotation.annotations[1].text)
            end)
            it("should highlight text", function()
                highlight_text("readerhighlight_pdf_ocr_text.png",
                               Geom:new{ x = 150, y = 100 },
                               Geom:new{ x = 560, y = 80 })
                assert.Equals(1, #readerui.annotation.annotations)
                --- @fixme: OCR should automatically kicks in.
                -- assert.Equals('that completely changes', readerui.annotation.annotations[1].text)
            end)
            it("should respond to tap gesture", function()
                tap_highlight_text("readerhighlight_pdf_ocr_tap.png",
                                   Geom:new{ x = 500, y = 120 },
                                   Geom:new{ x = 100, y = 150 },
                                   Geom:new{ x = 530, y = 125 })
            end)
        end)
        describe("for reflowed page", function()
            before_each(function()
                readerui.document.configurable.text_wrap = 1
                readerui.paging:onGotoPage(31)
            end)
            after_each(function()
                readerui.document.configurable.text_wrap = 0
            end)
            it("should highlight word", function()
                highlight_single_word("readerhighlight_pdf_reflow_word.png",
                                      Geom:new{ x = 260, y = 70 })
                assert.Equals(1, #readerui.annotation.annotations)
            end)
            it("should highlight text", function()
                highlight_text("readerhighlight_pdf_reflow_text.png",
                               Geom:new{ x = 260, y = 70 },
                               Geom:new{ x = 260, y = 150 })
                assert.Equals(1, #readerui.annotation.annotations)
            end)
            it("should response on tap gesture", function()
                tap_highlight_text("readerhighlight_pdf_reflow_tap.png",
                                   Geom:new{ x = 260, y = 70 },
                                   Geom:new{ x = 360, y = 75 },
                                   Geom:new{ x = 310, y = 80 })
            end)
        end)
    end)

    describe("highlight for PDF documents in scroll mode", function()
        setup(function()
            readerui = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument(sample_pdf),
                _testsuite = true,
            }
            readerui.document.configurable.trim_page = 3
            readerui.hinting.view.hinting = false
            readerui:handleEvent(Event:new("SetScrollMode", true))
            readerui.zooming:setZoomMode("contentwidth")
        end)
        teardown(function()
            readerui:onClose()
        end)
        before_each(function()
            UIManager:show(readerui)
        end)
        after_each(function()
            readerui.highlight:clear()
            readerui.annotation.annotations = {}
            UIManager:quit()
        end)
        describe("for scanned page with text layer", function()
            before_each(function()
                readerui.paging:onGotoPage(10)
            end)
            it("should highlight word", function()
                highlight_single_word("readerhighlight_pdf_scroll_layer_word.png",
                                      Geom:new{ x = 318, y = 62 })
                assert.Equals(1, #readerui.annotation.annotations)
                assert.Equals("VOLTAIRE", readerui.annotation.annotations[1].text)
            end)
            it("should highlight text", function()
                highlight_text("readerhighlight_pdf_scroll_layer_text.png",
                               Geom:new{ x = 86, y = 158 },
                               Geom:new{ x = 402, y = 145 })
                assert.Equals(1, #readerui.annotation.annotations)
                assert.Equals("The patriarch, George Fox,", readerui.annotation.annotations[1].text)
            end)
            it("should response on tap gesture", function()
                tap_highlight_text("readerhighlight_pdf_scroll_layer_tap.png",
                                   Geom:new{ x = 544, y = 601 },
                                   Geom:new{ x = 344, y = 626 },
                                   Geom:new{ x = 130, y = 625 })
                assert.Equals(1, #readerui.annotation.annotations)
                assert.Equals("Will iam Penn returned soon to England", readerui.annotation.annotations[1].text)
            end)
        end)
        describe("for scanned page without text layer", function()
            before_each(function()
                readerui.paging:onGotoPage(28)
            end)
            it("should highlight word", function()
                highlight_single_word("readerhighlight_pdf_scroll_ocr_word.png",
                                      Geom:new{ x = 107, y = 59 })
                assert.Equals(1, #readerui.annotation.annotations)
                --- @fixme: OCR should automatically kicks in.
                -- assert.Equals("geometers", readerui.annotation.annotations[1].text)
            end)
            it("should highlight text", function()
                highlight_text("readerhighlight_pdf_scroll_ocr_text.png",
                               Geom:new{x = 192, y = 186}, Geom:new{x = 262, y = 189})
                assert.Equals(1, #readerui.annotation.annotations)
                --- @fixme: OCR should automatically kicks in.
                -- assert.Equals("concrete objects", readerui.annotation.annotations[1].text)
            end)
            it("should response on tap gesture", function()
                tap_highlight_text("readerhighlight_pdf_scroll_ocr_tap.png",
                                   Geom:new{ x = 500, y = 125 },
                                   Geom:new{ x = 105, y = 150 },
                                   Geom:new{ x = 520, y = 130 })
                assert.Equals(1, #readerui.annotation.annotations)
                --- @fixme: OCR should automatically kicks in.
                -- assert.Equals("objects of knowledge", readerui.annotation.annotations[1].text)
            end)
        end)
        describe("for reflowed page", function()
            before_each(function()
                readerui.document.configurable.text_wrap = 1
                readerui.paging:onGotoPage(31)
            end)
            after_each(function()
                readerui.document.configurable.text_wrap = 0
            end)
            it("should highlight word", function()
                highlight_single_word("reader_highlight_single_word_pdf_reflowed_scroll.png",
                                      Geom:new{ x = 260, y = 70 })
                assert.Equals(1, #readerui.annotation.annotations)
                assert.Equals("hedging", readerui.annotation.annotations[1].text)
            end)
            it("should highlight text", function()
                highlight_text("reader_highlight_text_pdf_reflowed_scroll.png",
                               Geom:new{ x = 260, y = 70 }, Geom:new{ x = 260, y = 150 })
                assert.truthy(#readerui.annotation.annotations == 1)
            end)
            it("should response on tap gesture", function()
                tap_highlight_text("reader_tap_highlight_text_pdf_reflowed_scroll.png",
                                   Geom:new{ x = 239, y = 72 },
                                   Geom:new{ x = 383, y = 75 },
                                   Geom:new{ x = 312, y = 66 })
                assert.Equals('hedging using futures', readerui.annotation.annotations[1].text)
            end)
        end)
    end)

end)
