describe("Libra2Perf tuning", function()
    local Dispatcher, Tuning

    local function settings(initial)
        local data = initial or {}
        local flushed = false
        local writes = 0
        return {
            data = data,
            readSetting = function(_, key) return data[key] end,
            saveSetting = function(_, key, value)
                writes = writes + 1
                data[key] = value
            end,
            flush = function() flushed = true end,
            writeCount = function() return writes end,
            wasFlushed = function() return flushed end,
        }
    end

    local function currentGestureSettings()
        local gestures = settings({
            [Tuning.gesture_profile_key] = Tuning.gesture_profile_version,
            custom_multiswipes = {},
        })
        for mode, mode_profile in pairs(Tuning.gesture_profile) do
            gestures.data[mode] = {}
            for gesture, action_list in pairs(mode_profile) do
                gestures.data[mode][gesture] = action_list
            end
        end
        return gestures
    end

    setup(function()
        require("commonrequire")
        package.path = "plugins/libra2perf.koplugin/?.lua;" .. package.path
        Dispatcher = require("dispatcher")
        Tuning = require("tuning")
    end)

    it("detects Kobo Libra 2 only", function()
        assert.is_true(Tuning.isLibra2({
            model = "Kobo_io",
            isKobo = function() return true end,
        }))
        assert.is_false(Tuning.isLibra2({
            model = "Kobo_storm",
            isKobo = function() return true end,
        }))
        assert.is_false(Tuning.isLibra2({
            model = "Kobo_io",
            isKobo = function() return false end,
        }))
    end)

    it("applies the fast PDF and EPUB profile once", function()
        local defaults = settings()
        local reader_settings = settings()
        local gestures = settings()
        local screen = {}

        assert.is_true(Tuning.apply(defaults, reader_settings, screen, { gestures = gestures }))
        assert.are.equal(1, defaults.data.DHINTCOUNT)
        assert.are.equal(1024 * 1024 * 256, defaults.data.DGLOBAL_CACHE_SIZE_MAXIMUM)
        assert.are.equal(1.08, defaults.data.DKOPTREADER_CONFIG_CONTRAST)
        assert.are.equal(25000, defaults.data.DKOPTREADER_BACKGROUND_WAIT_US)
        assert.is_true(defaults.data.DKOPTREADER_DISABLE_OCR_FALLBACK)
        assert.are.equal(44, defaults.data.DGENERIC_ICON_SIZE)
        assert.are.equal(0.18, defaults.data.FOLLOW_LINK_TIMEOUT)
        assert.are.equal(0.12, defaults.data.DELAY_CLEAR_HIGHLIGHT_S)
        assert.are.equal(1/3, defaults.data.DTAP_ZONE_MENU.x)
        assert.are.equal(1/3, defaults.data.DTAP_ZONE_MENU.w)
        assert.are.equal(1/12, defaults.data.DTAP_ZONE_MENU.h)
        assert.are.equal(3/8, defaults.data.DTAP_ZONE_MENU_EXT.x)
        assert.are.equal(1/4, defaults.data.DTAP_ZONE_MENU_EXT.w)
        assert.are.equal(9/10, defaults.data.DTAP_ZONE_CONFIG.y)
        assert.are.equal(1/5, defaults.data.DTAP_ZONE_CONFIG.x)
        assert.are.equal(3/5, defaults.data.DTAP_ZONE_CONFIG.w)
        assert.are.equal(1/4, defaults.data.DTAP_ZONE_CONFIG_EXT.x)
        assert.are.equal(1/2, defaults.data.DTAP_ZONE_CONFIG_EXT.w)
        assert.are.equal(1/5, defaults.data.DTAP_ZONE_MINIBAR.x)
        assert.are.equal(3/5, defaults.data.DTAP_ZONE_MINIBAR.w)
        assert.are.equal(0.18, defaults.data.DTAP_ZONE_BACKWARD.w)
        assert.are.equal(0.82, defaults.data.DTAP_ZONE_FORWARD.w)
        assert.are.equal(12, defaults.data.DMINIBAR_CONTAINER_HEIGHT)
        assert.is_true(reader_settings.data.low_pan_rate)
        assert.is_false(reader_settings.data.flash_ui)
        assert.is_false(reader_settings.data.flash_keyboard)
        assert.is_false(reader_settings.data.swipe_animations)
        assert.are.equal(24, reader_settings.data.full_refresh_count)
        assert.is_true(reader_settings.data.disable_double_tap)
        assert.are.equal("left_right", reader_settings.data.page_turns_tap_zones)
        assert.are.equal(0.18, reader_settings.data.page_turns_tap_zone_backward_size_ratio)
        assert.are.equal(0.82, reader_settings.data.page_turns_tap_zone_forward_size_ratio)
        assert.are.equal("/mnt/onboard/Books", reader_settings.data.home_dir)
        assert.are.equal("/mnt/onboard/Books", reader_settings.data.lastdir)
        assert.is_true(reader_settings.data.lock_home_folder)
        assert.is_true(reader_settings.data.shorten_home_dir)
        assert.are.equal("filemanager", reader_settings.data.start_with)
        assert.are.equal("tap", reader_settings.data.activate_menu)
        assert.is_true(reader_settings.data.show_bottom_menu)
        assert.are.equal(1, reader_settings.data.readermenu_tab_index)
        assert.are.equal(1, reader_settings.data.filemanagermenu_tab_index)
        assert.is_false(reader_settings.data.open_last_menu_show_filename)
        assert.is_false(reader_settings.data.multiswipes_enabled)
        assert.is_false(reader_settings.data.show_file_in_bold)
        assert.is_false(reader_settings.data.show_hidden)
        assert.are.equal("strcoll", reader_settings.data.collate)
        assert.is_false(reader_settings.data.collate_mixed)
        assert.is_false(reader_settings.data.reverse_collate)
        assert.is_true(reader_settings.data.libra2_fast_filemanager_sort)
        assert.is_true(reader_settings.data.libra2_fast_filemanager_scan)
        assert.is_true(reader_settings.data.libra2_fast_filemanager_filter)
        assert.is_true(reader_settings.data.libra2_minimal_filemanager_details)
        assert.is_true(reader_settings.data.libra2_lazy_disabled_plugin_meta)
        assert.is_true(reader_settings.data.libra2_lazy_reader_sidepanels)
        assert.is_true(reader_settings.data.libra2_disable_reader_screenshot_module)
        assert.is_true(reader_settings.data.libra2_disable_reader_devicestatus_module)
        assert.is_false(reader_settings.data.libra2_disable_reader_networklistener)
        assert.is_true(reader_settings.data.auto_disable_wifi)
        assert.is_false(reader_settings.data.auto_restore_wifi)
        assert.are.equal("Books", reader_settings.data.folder_shortcuts["/mnt/onboard/Books"].text)
        assert.are.equal(128, reader_settings.data.cre_disk_cache_max_size)
        assert.are.equal(40, reader_settings.data.cre_storage_size_factor)
        assert.are.equal(35, reader_settings.data.ges_tap_interval_ms)
        assert.are.equal(350, reader_settings.data.ges_hold_interval_ms)
        assert.are.equal(220, reader_settings.data.ges_double_tap_interval_ms)
        assert.are.equal(700, reader_settings.data.ges_swipe_interval_ms)
        assert.are.equal(0.65, reader_settings.data.highlight_long_hold_threshold_s)
        assert.are.equal("bottom", reader_settings.data.highlight_dialog_position)
        assert.is_false(reader_settings.data.highlight_action_on_single_word)
        assert.are.equal("highlight", reader_settings.data.default_highlight_action)
        assert.is_true(reader_settings.data.disable_highlight_lookup_actions)
        assert.is_true(reader_settings.data.libra2_disable_lookup_modules)
        assert.is_true(reader_settings.data.tap_ignore_external_links)
        assert.is_false(reader_settings.data.larger_tap_area_to_follow_links)
        assert.is_true(reader_settings.data.swipe_ignore_external_links)
        assert.is_true(reader_settings.data.disable_ocr_fallback)
        assert.is_true(reader_settings.data.libra2_skip_unchanged_footer_update)
        assert.are.equal(1, reader_settings.data.reader_footer_mode)
        assert.is_true(reader_settings.data.footer.all_at_once)
        assert.is_false(reader_settings.data.footer.page_progress)
        assert.is_true(reader_settings.data.footer.percentage)
        assert.is_true(reader_settings.data.footer.time)
        assert.is_true(reader_settings.data.footer.battery)
        assert.is_false(reader_settings.data.footer.pages_left)
        assert.is_false(reader_settings.data.footer.book_time_to_read)
        assert.is_false(reader_settings.data.footer.chapter_time_to_read)
        assert.is_true(reader_settings.data.footer.progress_style_thin)
        assert.are.equal("below", reader_settings.data.footer.progress_bar_position)
        assert.are.equal("compact_items", reader_settings.data.footer.item_prefix)
        assert.are.equal(12, reader_settings.data.footer.text_font_size)
        assert.are.equal(14, reader_settings.data.footer.container_height)
        assert.are.equal(2, reader_settings.data.footer.progress_style_thin_height)
        assert.is_true(reader_settings.data.footer.skim_widget_on_hold)
        assert.is_false(reader_settings.data.footer.toc_markers)
        assert.are.equal("percentage", reader_settings.data.footer.order[0])
        assert.are.equal("time", reader_settings.data.footer.order[1])
        assert.are.equal("battery", reader_settings.data.footer.order[2])
        assert.is_nil(reader_settings.data.footer.order[3])
        assert.is_true(reader_settings.data.plugins_disabled.statistics)
        assert.is_true(reader_settings.data.plugins_disabled.coverbrowser)
        assert.are.equal(Tuning.gesture_profile_version, gestures.data[Tuning.gesture_profile_key])
        assert.is_true(gestures.data.gesture_reader.tap_top_right_corner.toggle_bookmark)
        assert.is_true(gestures.data.gesture_reader.hold_bottom_right_corner.settings.show_as_quickmenu)
        assert.are.equal("Reader", gestures.data.gesture_reader.hold_bottom_right_corner.settings.name)
        assert.is_true(gestures.data.gesture_reader.hold_bottom_right_corner.settings.anchor_quickmenu)
        assert.are.equal(0.54, gestures.data.gesture_reader.hold_bottom_right_corner.settings.quickmenu_min_width_factor)
        assert.are.equal("Format", gestures.data.gesture_reader.hold_bottom_right_corner.settings.labels.show_config_menu)
        assert.are.equal("Mark", gestures.data.gesture_reader.hold_bottom_right_corner.settings.labels.toggle_bookmark)
        assert.are.equal("A+", gestures.data.gesture_reader.hold_bottom_right_corner.settings.labels.increase_font)
        assert.are.equal("toc", gestures.data.gesture_reader.hold_bottom_right_corner.settings.order[1])
        assert.are.equal("go_to", gestures.data.gesture_reader.hold_bottom_right_corner.settings.order[2])
        assert.are.equal(0.5, gestures.data.gesture_reader.hold_bottom_right_corner.increase_font)
        assert.is_nil(gestures.data.gesture_reader.hold_bottom_right_corner.zoom)
        assert.is_nil(gestures.data.gesture_reader.hold_bottom_right_corner.fulltext_search)
        assert.is_nil(gestures.data.gesture_reader.hold_bottom_right_corner.skim)
        assert.are.equal("Display", gestures.data.gesture_reader.hold_bottom_left_corner.settings.name)
        assert.is_true(gestures.data.gesture_reader.hold_bottom_left_corner.settings.show_as_quickmenu)
        assert.are.equal(0.44, gestures.data.gesture_reader.hold_bottom_left_corner.settings.quickmenu_min_width_factor)
        assert.are.equal("Light", gestures.data.gesture_reader.hold_bottom_left_corner.settings.labels.show_frontlight_dialog)
        assert.are.equal("Fit", gestures.data.gesture_reader.hold_bottom_left_corner.settings.labels.zoom)
        assert.are.equal("show_frontlight_dialog", gestures.data.gesture_reader.hold_bottom_left_corner.settings.order[1])
        assert.is_true(gestures.data.gesture_reader.hold_bottom_left_corner.show_frontlight_dialog)
        assert.is_true(gestures.data.gesture_reader.hold_bottom_left_corner.toggle_reflow)
        assert.are.equal("contentwidth", gestures.data.gesture_reader.hold_bottom_left_corner.zoom)
        assert.is_true(gestures.data.gesture_reader.hold_bottom_left_corner.full_refresh)
        assert.is_true(gestures.data.gesture_fm.hold_bottom_right_corner.settings.show_as_quickmenu)
        assert.are.equal("Library", gestures.data.gesture_fm.hold_bottom_right_corner.settings.name)
        assert.are.equal(0.50, gestures.data.gesture_fm.hold_bottom_right_corner.settings.quickmenu_min_width_factor)
        assert.are.equal("Search", gestures.data.gesture_fm.hold_bottom_right_corner.settings.labels.file_search)
        assert.are.equal("history", gestures.data.gesture_fm.hold_bottom_right_corner.settings.order[1])
        assert.are.equal("folder_shortcuts", gestures.data.gesture_fm.hold_bottom_right_corner.settings.order[2])
        assert.are.equal("file_search", gestures.data.gesture_fm.hold_bottom_right_corner.settings.order[3])
        assert.is_nil(gestures.data.gesture_fm.hold_bottom_right_corner.favorites)
        assert.is_nil(gestures.data.gesture_fm.hold_bottom_right_corner.collections)
        assert.is_true(gestures.wasFlushed())
        assert.is_true(screen.low_pan_rate)
        assert.is_true(defaults.wasFlushed())
        assert.is_true(reader_settings.wasFlushed())

        reader_settings.data.flash_ui = true
        assert.is_false(Tuning.apply(defaults, reader_settings, screen))
        assert.is_true(reader_settings.data.flash_ui)
    end)

    it("can force reapply the profile", function()
        local defaults = settings()
        local reader_settings = settings({
            [Tuning.profile_key] = Tuning.profile_version,
            flash_ui = true,
        })
        local gestures = settings({
            [Tuning.gesture_profile_key] = Tuning.gesture_profile_version,
            gesture_reader = {
                hold_bottom_right_corner = {
                    custom = true,
                },
            },
        })

        assert.is_true(Tuning.apply(defaults, reader_settings, nil, {
            force = true,
            gestures = gestures,
        }))
        assert.is_false(reader_settings.data.flash_ui)
        assert.is_nil(gestures.data.gesture_reader.hold_bottom_right_corner.custom)
        assert.are.equal("Reader", gestures.data.gesture_reader.hold_bottom_right_corner.settings.name)
    end)

    it("preserves existing folder shortcuts while adding Books", function()
        local defaults = settings()
        local reader_settings = settings({
            folder_shortcuts = {
                ["/mnt/onboard/Manuals"] = { text = "Manuals", time = 1 },
            },
        })

        assert.is_true(Tuning.apply(defaults, reader_settings, nil, { force = true }))
        assert.are.equal("Manuals", reader_settings.data.folder_shortcuts["/mnt/onboard/Manuals"].text)
        assert.are.equal("Books", reader_settings.data.folder_shortcuts["/mnt/onboard/Books"].text)
    end)

    it("preserves unknown footer keys while applying the reading UX profile", function()
        local defaults = settings()
        local reader_settings = settings({
            footer = {
                custom_future_key = "keep-me",
                time = false,
            },
        })

        assert.is_true(Tuning.apply(defaults, reader_settings, nil, { force = true }))
        assert.are.equal("keep-me", reader_settings.data.footer.custom_future_key)
        assert.is_true(reader_settings.data.footer.time)
    end)

    it("preserves an already current gesture profile unless forced", function()
        local gestures = currentGestureSettings()

        assert.is_false(Tuning.seedGestureProfile(gestures))
        assert.are.equal("Reader", gestures.data.gesture_reader.hold_bottom_right_corner.settings.name)
    end)

    it("repairs a stale gesture profile even when the version marker is current", function()
        local gestures = settings({
            [Tuning.gesture_profile_key] = Tuning.gesture_profile_version,
            gesture_reader = {},
            gesture_fm = {},
            custom_multiswipes = {},
        })

        assert.is_true(Tuning.seedGestureProfile(gestures))
        assert.are.equal("Reader", gestures.data.gesture_reader.hold_bottom_right_corner.settings.name)
        assert.are.equal("Library", gestures.data.gesture_fm.hold_bottom_right_corner.settings.name)
    end)

    it("repairs missing gestures without rewriting an already current reader profile", function()
        local defaults = settings()
        local reader_settings = settings({
            [Tuning.profile_key] = Tuning.profile_version,
            flash_ui = true,
        })
        local gestures = settings({
            gesture_reader = {
                tap_top_right_corner = {
                    toggle_bookmark = true,
                },
            },
        })

        assert.is_true(Tuning.apply(defaults, reader_settings, nil, { gestures = gestures }))
        assert.is_true(reader_settings.data.flash_ui)
        assert.are.equal(0, defaults.writeCount())
        assert.are.equal(0, reader_settings.writeCount())
        assert.is_false(defaults.wasFlushed())
        assert.is_false(reader_settings.wasFlushed())
        assert.is_true(gestures.wasFlushed())
        assert.are.equal(Tuning.gesture_profile_version, gestures.data[Tuning.gesture_profile_key])
        assert.are.equal("Reader", gestures.data.gesture_reader.hold_bottom_right_corner.settings.name)
    end)

    it("shows concise QuickMenu labels for the Libra 2 control surface", function()
        local gestures = currentGestureSettings()
        local reading = Dispatcher.getDisplayList(gestures.data.gesture_reader.hold_bottom_right_corner)
        local display = Dispatcher.getDisplayList(gestures.data.gesture_reader.hold_bottom_left_corner)
        local library = Dispatcher.getDisplayList(gestures.data.gesture_fm.hold_bottom_right_corner)

        assert.are.equal("Contents", reading[1].text)
        assert.are.equal("Page", reading[2].text)
        assert.are.equal("Mark", reading[3].text)
        assert.are.equal("Format", reading[4].text)
        assert.are.equal("A+", reading[5].text)
        assert.are.equal("A-", reading[6].text)
        assert.are.equal(6, #reading)
        assert.are.equal("Light", display[1].text)
        assert.are.equal("Reflow", display[2].text)
        assert.are.equal("Fit", display[3].text)
        assert.are.equal("Refresh", display[4].text)
        assert.are.equal("Recent", library[1].text)
        assert.are.equal("Folders", library[2].text)
        assert.are.equal("Search", library[3].text)
        assert.are.equal("More", library[5].text)
        assert.are.equal(5, #library)
    end)

    it("sets runtime screen tuning even when the persisted profile is current", function()
        local defaults = settings()
        local reader_settings = settings({
            [Tuning.profile_key] = Tuning.profile_version,
        })
        local gestures = currentGestureSettings()
        local screen = {}

        assert.is_true(Tuning.apply(defaults, reader_settings, screen, { gestures = gestures }))
        assert.is_true(screen.low_pan_rate)
        assert.are.equal(0, defaults.writeCount())
        assert.are.equal(0, reader_settings.writeCount())
        assert.is_false(defaults.wasFlushed())
        assert.is_false(reader_settings.wasFlushed())
        assert.is_false(gestures.wasFlushed())

        assert.is_false(Tuning.apply(defaults, reader_settings, screen, { gestures = gestures }))
    end)

    it("skips disk writes when a forced profile already matches persisted values", function()
        local defaults = settings(Tuning.defaults)
        local reader_settings = settings({})
        for key, value in pairs(Tuning.reader_settings) do
            reader_settings.data[key] = value
        end
        reader_settings.data.footer = Tuning.footer_settings
        reader_settings.data.reader_footer_mode = 1
        reader_settings.data.folder_shortcuts = {
            [Tuning.books_dir] = {
                text = "Books",
                time = 0,
            },
        }
        reader_settings.data.plugins_disabled = {}
        for name in pairs(Tuning.disabled_plugins) do
            reader_settings.data.plugins_disabled[name] = true
        end
        reader_settings.data[Tuning.profile_key] = Tuning.profile_version
        local gestures = currentGestureSettings()
        local screen = {
            low_pan_rate = true,
        }

        assert.is_false(Tuning.apply(defaults, reader_settings, screen, {
            force = true,
            gestures = gestures,
        }))
        assert.are.equal(0, defaults.writeCount())
        assert.are.equal(0, reader_settings.writeCount())
        assert.is_false(defaults.wasFlushed())
        assert.is_false(reader_settings.wasFlushed())
        assert.is_false(gestures.wasFlushed())
    end)
end)
