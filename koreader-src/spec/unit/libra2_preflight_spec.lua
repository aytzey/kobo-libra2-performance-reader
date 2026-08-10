describe("Libra 2 preflight", function()
    local DataStorage, Preflight, Tuning

    local function settings(initial)
        local data = initial or {}
        local writes = 0
        local flushed = false
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

    local function writeVersion(name, text)
        local path = DataStorage:getDataDir() .. "/" .. name
        local file = assert(io.open(path, "w"))
        file:write(text)
        file:close()
        return path
    end

    setup(function()
        package.path = "plugins/libra2perf.koplugin/?.lua;" .. package.path
        DataStorage = require("datastorage")
        Preflight = require("preflight")
        Tuning = require("tuning")
    end)

    it("detects Libra 2 model version lines", function()
        local libra2 = writeVersion("libra2-preflight-yes.version", "N873xxxxxxxxxxxxxxxx388\n")
        local other = writeVersion("libra2-preflight-no.version", "N873xxxxxxxxxxxxxxxx397\n")

        assert.is_true(Preflight.isLibra2Version(libra2))
        assert.is_false(Preflight.isLibra2Version(other))
        assert.is_false(Preflight.isLibra2Version(DataStorage:getDataDir() .. "/missing.version"))

        os.remove(libra2)
        os.remove(other)
    end)

    it("skips non-Libra 2 devices before touching settings", function()
        local defaults = settings()
        local reader_settings = settings()
        local version = writeVersion("libra2-preflight-skip.version", "N873xxxxxxxxxxxxxxxx397\n")

        local applied, reason = Preflight.run{
            defaults = defaults,
            settings = reader_settings,
            tuning = Tuning,
            version_path = version,
        }

        assert.is_false(applied)
        assert.are.equal("not-libra2", reason)
        assert.are.equal(0, defaults.writeCount())
        assert.are.equal(0, reader_settings.writeCount())

        os.remove(version)
    end)

    it("seeds the profile before plugin discovery", function()
        local defaults = settings()
        local reader_settings = settings()
        local gestures = settings()

        assert.is_true(Preflight.run{
            defaults = defaults,
            settings = reader_settings,
            gestures = gestures,
            tuning = Tuning,
            skip_model_check = true,
        })

        assert.are.equal(Tuning.profile_version, reader_settings.data[Tuning.profile_key])
        assert.are.equal(1, defaults.data.DHINTCOUNT)
        assert.are.equal(25000, defaults.data.DKOPTREADER_BACKGROUND_WAIT_US)
        assert.are.equal(44, defaults.data.DGENERIC_ICON_SIZE)
        assert.are.equal(1/5, defaults.data.DTAP_ZONE_MINIBAR.x)
        assert.are.equal(3/5, defaults.data.DTAP_ZONE_MINIBAR.w)
        assert.are.equal(0.82, defaults.data.DTAP_ZONE_FORWARD.w)
        assert.are.equal(12, defaults.data.DMINIBAR_CONTAINER_HEIGHT)
        assert.is_true(reader_settings.data.disable_double_tap)
        assert.are.equal(0.82, reader_settings.data.page_turns_tap_zone_forward_size_ratio)
        assert.are.equal("/mnt/onboard/Books", reader_settings.data.home_dir)
        assert.are.equal("/mnt/onboard/Books", reader_settings.data.lastdir)
        assert.is_true(reader_settings.data.lock_home_folder)
        assert.are.equal("tap", reader_settings.data.activate_menu)
        assert.is_true(reader_settings.data.show_bottom_menu)
        assert.is_false(reader_settings.data.open_last_menu_show_filename)
        assert.is_false(reader_settings.data.show_file_in_bold)
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
        assert.are.equal(350, reader_settings.data.ges_hold_interval_ms)
        assert.are.equal(Tuning.gesture_profile_version, gestures.data[Tuning.gesture_profile_key])
        assert.are.equal("Reader", gestures.data.gesture_reader.hold_bottom_right_corner.settings.name)
        assert.are.equal("Display", gestures.data.gesture_reader.hold_bottom_left_corner.settings.name)
        assert.are.equal("Library", gestures.data.gesture_fm.hold_bottom_right_corner.settings.name)
        assert.are.equal("bottom", reader_settings.data.highlight_dialog_position)
        assert.is_false(reader_settings.data.highlight_action_on_single_word)
        assert.are.equal("highlight", reader_settings.data.default_highlight_action)
        assert.is_true(reader_settings.data.disable_highlight_lookup_actions)
        assert.is_true(reader_settings.data.libra2_disable_lookup_modules)
        assert.is_true(reader_settings.data.tap_ignore_external_links)
        assert.is_true(reader_settings.data.libra2_skip_unchanged_footer_update)
        assert.are.equal(1, reader_settings.data.reader_footer_mode)
        assert.is_true(reader_settings.data.footer.all_at_once)
        assert.is_false(reader_settings.data.footer.page_progress)
        assert.is_true(reader_settings.data.footer.percentage)
        assert.is_true(reader_settings.data.footer.progress_style_thin)
        assert.are.equal("below", reader_settings.data.footer.progress_bar_position)
        assert.are.equal("compact_items", reader_settings.data.footer.item_prefix)
        assert.are.equal("dot", reader_settings.data.footer.items_separator)
        assert.are.equal(12, reader_settings.data.footer.text_font_size)
        assert.are.equal(14, reader_settings.data.footer.container_height)
        assert.is_true(reader_settings.data.footer.skim_widget_on_hold)
        assert.is_false(reader_settings.data.footer.book_time_to_read)
        assert.is_true(reader_settings.data.plugins_disabled.statistics)
        assert.is_true(reader_settings.data.plugins_disabled.coverbrowser)
        assert.is_true(defaults.wasFlushed())
        assert.is_true(reader_settings.wasFlushed())
    end)

    it("does not rewrite settings when the profile is current", function()
        local defaults = settings()
        local reader_settings = settings({
            [Tuning.profile_key] = Tuning.profile_version,
        })
        local gestures = currentGestureSettings()

        assert.is_false(Preflight.run{
            defaults = defaults,
            settings = reader_settings,
            gestures = gestures,
            tuning = Tuning,
            skip_model_check = true,
        })
        assert.are.equal(0, defaults.writeCount())
        assert.are.equal(0, reader_settings.writeCount())
    end)

    it("can repair gestures while leaving current settings untouched", function()
        local defaults = settings()
        local reader_settings = settings({
            [Tuning.profile_key] = Tuning.profile_version,
        })
        local gestures = settings()

        assert.is_true(Preflight.run{
            defaults = defaults,
            settings = reader_settings,
            gestures = gestures,
            tuning = Tuning,
            skip_model_check = true,
        })
        assert.are.equal(0, defaults.writeCount())
        assert.are.equal(0, reader_settings.writeCount())
        assert.are.equal("Reader", gestures.data.gesture_reader.hold_bottom_right_corner.settings.name)
        assert.are.equal("Display", gestures.data.gesture_reader.hold_bottom_left_corner.settings.name)
        assert.is_true(gestures.wasFlushed())
    end)
end)
