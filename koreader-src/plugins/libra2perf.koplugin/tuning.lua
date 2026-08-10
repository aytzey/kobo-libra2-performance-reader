local Tuning = {
    profile_version = 21,
    profile_key = "libra2_perf_profile_version",
    gesture_profile_version = 7,
    gesture_profile_key = "libra2_perf_gesture_profile_version",
    books_dir = "/mnt/onboard/Books",
}

Tuning.defaults = {
    DHINTCOUNT = 1,
    DGLOBAL_CACHE_SIZE_MINIMUM = 1024 * 1024 * 32,
    DGLOBAL_CACHE_FREE_PROPORTION = 0.55,
    DGLOBAL_CACHE_SIZE_MAXIMUM = 1024 * 1024 * 256,
    DKOPTREADER_CONFIG_TRIM_PAGE = 1,
    DKOPTREADER_CONFIG_PAGE_MARGIN = 0.06,
    DKOPTREADER_CONFIG_CONTRAST = 1.08,
    DKOPTREADER_BACKGROUND_WAIT_US = 25000,
    DKOPTREADER_DISABLE_OCR_FALLBACK = true,
    DGENERIC_ICON_SIZE = 44,
    FOLLOW_LINK_TIMEOUT = 0.18,
    DELAY_CLEAR_HIGHLIGHT_S = 0.12,
    DTAP_ZONE_MENU = { x = 1/3, y = 0, w = 1/3, h = 1/12 },
    DTAP_ZONE_MENU_EXT = { x = 3/8, y = 0, w = 1/4, h = 1/8 },
    DTAP_ZONE_CONFIG = { x = 1/5, y = 9/10, w = 3/5, h = 1/10 },
    DTAP_ZONE_CONFIG_EXT = { x = 1/4, y = 5/6, w = 1/2, h = 1/6 },
    DTAP_ZONE_MINIBAR = { x = 1/5, y = 12/13, w = 3/5, h = 1/13 },
    DTAP_ZONE_FORWARD = { x = 0.18, y = 0, w = 0.82, h = 1 },
    DTAP_ZONE_BACKWARD = { x = 0, y = 0, w = 0.18, h = 1 },
    DDOUBLE_TAP_ZONE_NEXT_CHAPTER = { x = 0.18, y = 0, w = 0.82, h = 1 },
    DDOUBLE_TAP_ZONE_PREV_CHAPTER = { x = 0, y = 0, w = 0.18, h = 1 },
    DMINIBAR_CONTAINER_HEIGHT = 12,
}

Tuning.reader_settings = {
    low_pan_rate = true,
    flash_ui = false,
    flash_keyboard = false,
    avoid_flashing_ui = true,
    swipe_animations = false,
    full_refresh_count = 24,
    night_full_refresh_count = 12,
    disable_double_tap = true,
    page_turns_tap_zones = "left_right",
    page_turns_tap_zone_backward_size_ratio = 0.18,
    page_turns_tap_zone_forward_size_ratio = 0.82,
    home_dir = Tuning.books_dir,
    lastdir = Tuning.books_dir,
    lock_home_folder = true,
    shorten_home_dir = true,
    start_with = "filemanager",
    activate_menu = "tap",
    show_bottom_menu = true,
    readermenu_tab_index = 1,
    filemanagermenu_tab_index = 1,
    open_last_menu_show_filename = false,
    multiswipes_enabled = false,
    show_file_in_bold = false,
    show_hidden = false,
    collate = "strcoll",
    collate_mixed = false,
    reverse_collate = false,
    libra2_fast_filemanager_sort = true,
    libra2_fast_filemanager_scan = true,
    libra2_fast_filemanager_filter = true,
    libra2_minimal_filemanager_details = true,
    libra2_lazy_disabled_plugin_meta = true,
    libra2_lazy_reader_sidepanels = true,
    libra2_disable_reader_screenshot_module = true,
    libra2_disable_reader_devicestatus_module = true,
    libra2_disable_reader_networklistener = false,
    auto_disable_wifi = true,
    auto_restore_wifi = false,
    document_metadata_folder = "dir",
    cre_disk_cache_max_size = 128,
    cre_compress_cached_data = false,
    cre_storage_size_factor = 40,
    ges_tap_interval_ms = 35,
    ges_hold_interval_ms = 350,
    ges_double_tap_interval_ms = 220,
    ges_swipe_interval_ms = 700,
    highlight_long_hold_threshold_s = 0.65,
    highlight_dialog_position = "bottom",
    highlight_action_on_single_word = false,
    default_highlight_action = "highlight",
    disable_highlight_lookup_actions = true,
    libra2_disable_lookup_modules = true,
    tap_ignore_external_links = true,
    larger_tap_area_to_follow_links = false,
    swipe_ignore_external_links = true,
    disable_ocr_fallback = true,
    libra2_skip_unchanged_footer_update = true,
}

Tuning.footer_settings = {
    disable_progress_bar = false,
    chapter_progress_bar = false,
    disabled = false,
    all_at_once = true,
    reclaim_height = false,
    toc_markers = false,
    page_progress = false,
    pages_left_book = false,
    time = true,
    pages_left = false,
    battery = true,
    percentage = true,
    book_time_to_read = false,
    chapter_time_to_read = false,
    frontlight = false,
    mem_usage = false,
    wifi_status = false,
    page_turning_inverted = false,
    book_author = false,
    book_title = false,
    book_chapter = false,
    bookmark_count = false,
    chapter_progress = false,
    item_prefix = "compact_items",
    text_font_size = 12,
    text_font_bold = false,
    container_height = 14,
    container_bottom_padding = 1,
    progress_margin_width = 18,
    progress_margin = false,
    progress_bar_min_width_pct = 28,
    skim_widget_on_hold = true,
    progress_style_thin = true,
    progress_bar_position = "below",
    bottom_horizontal_separator = false,
    align = "center",
    auto_refresh_time = false,
    progress_style_thin_height = 2,
    hide_empty_generators = true,
    lock_tap = false,
    items_separator = "dot",
    progress_pct_format = "0",
    pages_left_includes_current_page = false,
    initial_marker = false,
    invert_progress_direction = false,
    order = {
        [0] = "percentage",
        "time",
        "battery",
    },
}

Tuning.disabled_plugins = {
    ["SSH"] = true,
    autoturn = true,
    calibre = true,
    coverbrowser = true,
    externalkeyboard = true,
    httpinspector = true,
    japanese = true,
    kosync = true,
    newsdownloader = true,
    opds = true,
    perceptionexpander = true,
    qrclipboard = true,
    readtimer = true,
    statistics = true,
    terminal = true,
    timesync = true,
    vocabbuilder = true,
    wallabag = true,
}

Tuning.gesture_profile = {
    gesture_reader = {
        hold_bottom_right_corner = {
            settings = {
                name = "Reader",
                show_as_quickmenu = true,
                keep_open_on_apply = true,
                anchor_quickmenu = true,
                quickmenu_min_width_factor = 0.54,
                labels = {
                    show_config_menu = "Format",
                    toc = "Contents",
                    go_to = "Page",
                    toggle_bookmark = "Mark",
                    increase_font = "A+",
                    decrease_font = "A-",
                },
                order = {
                    "toc",
                    "go_to",
                    "toggle_bookmark",
                    "show_config_menu",
                    "increase_font",
                    "decrease_font",
                },
                quickmenu_separators = {
                    go_to = true,
                    show_config_menu = true,
                    decrease_font = true,
                },
            },
            show_config_menu = true,
            toc = true,
            go_to = true,
            toggle_bookmark = true,
            increase_font = 0.5,
            decrease_font = 0.5,
        },
        hold_bottom_left_corner = {
            settings = {
                name = "Display",
                show_as_quickmenu = true,
                keep_open_on_apply = false,
                anchor_quickmenu = true,
                quickmenu_min_width_factor = 0.44,
                labels = {
                    show_frontlight_dialog = "Light",
                    toggle_reflow = "Reflow",
                    zoom = "Fit",
                    full_refresh = "Refresh",
                },
                order = {
                    "show_frontlight_dialog",
                    "toggle_reflow",
                    "zoom",
                    "full_refresh",
                },
                quickmenu_separators = {
                    show_frontlight_dialog = true,
                    zoom = true,
                },
            },
            show_frontlight_dialog = true,
            toggle_reflow = true,
            zoom = "contentwidth",
            full_refresh = true,
        },
    },
    gesture_fm = {
        hold_bottom_right_corner = {
            settings = {
                name = "Library",
                show_as_quickmenu = true,
                keep_open_on_apply = false,
                anchor_quickmenu = true,
                quickmenu_min_width_factor = 0.50,
                labels = {
                    file_search = "Search",
                    folder_shortcuts = "Folders",
                    history = "Recent",
                    refresh_content = "Refresh",
                    show_plus_menu = "More",
                },
                order = {
                    "history",
                    "folder_shortcuts",
                    "file_search",
                    "refresh_content",
                    "show_plus_menu",
                },
                quickmenu_separators = {
                    folder_shortcuts = true,
                    refresh_content = true,
                },
            },
            file_search = true,
            folder_shortcuts = true,
            history = true,
            refresh_content = true,
            show_plus_menu = true,
        },
        hold_bottom_left_corner = {
            show_frontlight_dialog = true,
        },
    },
}

function Tuning.isLibra2(device)
    return device and device.isKobo and device:isKobo() and device.model == "Kobo_io"
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, child in pairs(value) do
        copy[deepCopy(key)] = deepCopy(child)
    end
    return copy
end

local function sameValue(left, right)
    if left == right then
        return true
    end
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    for key, value in pairs(left) do
        if not sameValue(value, right[key]) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function saveChanged(settings, key, value)
    if sameValue(settings:readSetting(key), value) then
        return false
    end
    settings:saveSetting(key, value)
    return true
end

local function saveAll(settings, values)
    local changed = false
    for key, value in pairs(values) do
        changed = saveChanged(settings, key, value) or changed
    end
    return changed
end

local function saveTableSetting(settings, key, values)
    local data = settings:readSetting(key) or {}
    local changed = false
    for setting_key, value in pairs(values) do
        if not sameValue(data[setting_key], value) then
            data[setting_key] = value
            changed = true
        end
    end
    if changed then
        settings:saveSetting(key, data)
    end
    return changed
end

local function disableBackgroundPlugins(settings)
    local plugins_disabled = settings:readSetting("plugins_disabled") or {}
    local changed = false
    for name in pairs(Tuning.disabled_plugins) do
        if plugins_disabled[name] ~= true then
            plugins_disabled[name] = true
            changed = true
        end
    end
    if changed then
        settings:saveSetting("plugins_disabled", plugins_disabled)
    end
    return changed
end

local function ensureBooksFolder(path)
    local ok, lfs = pcall(require, "lfs")
    if not ok then return false end
    if lfs.attributes(path, "mode") == "directory" then return true end

    local parent = path:match("^(.*)/[^/]+/?$")
    if not parent or lfs.attributes(parent, "mode") ~= "directory" then
        return false
    end

    lfs.mkdir(path)
    return lfs.attributes(path, "mode") == "directory"
end

local function seedBooksFolderShortcut(settings)
    local shortcuts = settings:readSetting("folder_shortcuts") or {}
    if shortcuts[Tuning.books_dir] then
        return false
    end
    shortcuts[Tuning.books_dir] = {
        text = "Books",
        time = 0,
    }
    settings:saveSetting("folder_shortcuts", shortcuts)
    return true
end

local function readGestureDefaults()
    local ok, defaults = pcall(dofile, "plugins/gestures.koplugin/defaults.lua")
    if ok and type(defaults) == "table" then
        return defaults
    end
    return {
        gesture_reader = {},
        gesture_fm = {},
        custom_multiswipes = {},
    }
end

function Tuning.openGestureSettings()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    local ok_ffi, ffiUtil = pcall(require, "ffi/util")
    if not ok_ds or not ok_ls or not ok_ffi then
        return nil
    end
    return LuaSettings:open(ffiUtil.joinPath(DataStorage:getSettingsDir(), "gestures.lua"))
end

function Tuning.seedGestureProfile(gestures, opts)
    opts = opts or {}
    if not gestures then
        return false
    end
    gestures.data = type(gestures.data) == "table" and gestures.data or {}
    local changed = false

    if not next(gestures.data) then
        gestures.data = deepCopy(readGestureDefaults())
        changed = true
    end
    if not gestures.data.gesture_reader then
        gestures.data.gesture_reader = {}
        changed = true
    end
    if not gestures.data.gesture_fm then
        gestures.data.gesture_fm = {}
        changed = true
    end
    if not gestures.data.custom_multiswipes then
        gestures.data.custom_multiswipes = {}
        changed = true
    end

    for mode, mode_profile in pairs(Tuning.gesture_profile) do
        for gesture, action_list in pairs(mode_profile) do
            if not sameValue(gestures.data[mode][gesture], action_list) then
                gestures.data[mode][gesture] = deepCopy(action_list)
                changed = true
            end
        end
    end

    if gestures.data[Tuning.gesture_profile_key] ~= Tuning.gesture_profile_version then
        gestures.data[Tuning.gesture_profile_key] = Tuning.gesture_profile_version
        changed = true
    end
    return changed
end

function Tuning.apply(defaults, settings, screen, opts)
    opts = opts or {}
    local current_version = settings:readSetting(Tuning.profile_key)
    local gestures = opts.gestures
    local gestures_updated = Tuning.seedGestureProfile(gestures, { force = opts.force })
    local screen_updated = false
    if screen and screen.low_pan_rate ~= true then
        screen.low_pan_rate = true
        screen_updated = true
    end
    if not opts.force and current_version == Tuning.profile_version then
        if gestures_updated and gestures.flush then gestures:flush() end
        return gestures_updated or screen_updated
    end

    ensureBooksFolder(Tuning.books_dir)
    local defaults_updated = saveAll(defaults, Tuning.defaults)
    local settings_updated = saveAll(settings, Tuning.reader_settings)
    settings_updated = saveTableSetting(settings, "footer", Tuning.footer_settings) or settings_updated
    settings_updated = saveChanged(settings, "reader_footer_mode", 1) or settings_updated
    settings_updated = seedBooksFolderShortcut(settings) or settings_updated
    settings_updated = disableBackgroundPlugins(settings) or settings_updated

    settings_updated = saveChanged(settings, Tuning.profile_key, Tuning.profile_version) or settings_updated

    if defaults_updated and defaults.flush then defaults:flush() end
    if settings_updated and settings.flush then settings:flush() end
    if gestures_updated and gestures.flush then gestures:flush() end

    return defaults_updated or settings_updated or gestures_updated or screen_updated
end

return Tuning
