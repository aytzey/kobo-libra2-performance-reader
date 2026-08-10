local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local logger = require("logger")
local rapidjson = require("rapidjson")
local sha2 = require("ffi/sha2")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local ffi_ok, ffi = pcall(require, "ffi")
local _ = require("gettext")
local T = require("ffi/util").template

local Engine = require("ttsengine")
local Screen = Device.screen
local SIGTERM = 15
local SIGCONT = 18
local SIGSTOP = 19
local BT_TIMEOUT_MARKER = "::TTSREADER_BT_TIMEOUT::"
local BT_STACK_FAILED_MARKER = "::TTSREADER_BT_STACK_FAILED::"
local ttsreader_player_cdef_loaded = false

local TTSReaderPlayerBar = InputContainer:extend{
    name = "ttsreader_player_bar",
    bar_height = 458,
    margin = 0,
    padding = 18,
    button_h = 74,
    small_button_h = 58,
    progress_h = 12,
    controls_bottom_inset = 26,
}

local TTSReaderGenerationBar = InputContainer:extend{
    name = "ttsreader_generation_bar",
    bar_height = 124,
    margin = 8,
    padding = 8,
    button_w = 150,
    button_h = 58,
    progress_h = 8,
}

local TTSReader = WidgetContainer:extend{
    name = "ttsreader",
    is_doc_only = false,
    key_server_port = 23119,
    generation_step_delay = 0.18,
    playback_ui_min_interval = 1.15,
    bluetooth_idle_poweroff_seconds = 90,
    headset_input_bar_validate_interval = 15,
    headset_input_missing_scan_interval = 20,
}

local function fileExists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function fileSize(path)
    local file = io.open(path, "rb")
    if not file then
        return 0
    end
    local size = tonumber(file:seek("end")) or 0
    file:close()
    return size
end

local function shellQuote(value)
    return Engine.shellQuote(value)
end

local function firstLine(command)
    local handle = io.popen(command)
    if not handle then
        return nil
    end
    local line = handle:read("*l")
    handle:close()
    return line
end

local function commandOutput(command)
    local handle = io.popen(command)
    if not handle then
        return "", false
    end
    local output = handle:read("*a") or ""
    local ok = handle:close()
    return output, ok
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return ""
    end
    local data = file:read("*a") or ""
    file:close()
    return data
end

local function writeFile(path, data, mode)
    local file, err = io.open(path, mode or "wb")
    if not file then
        return false, err
    end
    file:write(data or "")
    file:close()
    return true
end

local function avrcpInputDevices()
    return Engine.bluetoothInputDevicesFromProc(readFile("/proc/bus/input/devices"))
end

local function avrcpInputDevicePaths()
    return Engine.bluetoothInputDevicePathsFromProc(readFile("/proc/bus/input/devices"))
end

local function removeFile(path)
    if path and path ~= "" then
        os.remove(path)
    end
end

local function moveFile(src, dst)
    removeFile(dst)
    local ok, err = os.rename(src, dst)
    if ok then
        return true
    end
    local status = os.execute("mv -f " .. shellQuote(src) .. " " .. shellQuote(dst) .. " >/dev/null 2>&1")
    if status == true or status == 0 then
        return true
    end
    return false, err or status
end

local function clamp(value, low, high)
    if value < low then
        return low
    elseif value > high then
        return high
    end
    return value
end

local function shortLine(text)
    text = tostring(text or ""):gsub("%s+", " ")
    if #text > 92 then
        return text:sub(1, 89) .. "..."
    end
    return text
end

function TTSReaderGenerationBar:init()
    self.ges_events.TapTTSReaderGenerationBar = {
        GestureRange:new{
            ges = "tap",
            range = self:_barRect(),
        },
    }
end

function TTSReaderGenerationBar:_barHeight()
    return math.max(self.bar_height, math.floor(Screen:getHeight() * 0.074))
end

function TTSReaderGenerationBar:_barRect()
    local h = self:_barHeight()
    return Geom:new{
        x = 0,
        y = math.max(0, Screen:getHeight() - h),
        w = Screen:getWidth(),
        h = h,
    }
end

function TTSReaderGenerationBar:_updateGestureRange()
    local event = self.ges_events and self.ges_events.TapTTSReaderGenerationBar
    if event and event[1] then
        event[1].range = self:_barRect()
    end
end

function TTSReaderGenerationBar:getSize()
    return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

function TTSReaderGenerationBar:_drawText(bb, text, face, x, y, max_width, bold, color)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = bold == true,
        max_width = max_width,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
    }
    widget:paintTo(bb, x, y)
    local size = widget:getSize()
    widget:free()
    return size
end

function TTSReaderGenerationBar:_drawCenteredText(bb, text, face, x, y, width, bold, color)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = bold == true,
        max_width = width,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
    }
    local size = widget:getSize()
    local text_x = x + math.max(0, math.floor((width - size.w) / 2))
    widget:paintTo(bb, text_x, y)
    widget:free()
    return size
end

function TTSReaderGenerationBar:_snapshot()
    local owner = self.owner
    local gen = owner and owner.generation
    if not gen or not gen.active then
        return nil
    end

    local total = math.max(1, (tonumber(gen.end_page) or 0) - (tonumber(gen.start_page) or 0) + 1)
    local done = math.max(0, tonumber(gen.done) or 0)
    local page = tonumber(gen.current_page) or tonumber(gen.next_page) or tonumber(gen.start_page) or 0
    local pct = clamp(done / total, 0, 1)
    local percent = math.floor(pct * 100 + 0.5)
    local state = gen.current_page and _("Hazirlaniyor") or _("Bekliyor")
    local label = gen.label or (gen.mode == "redownload" and _("Bastan indir") or _("Eksikler"))
    return {
        title = T(_("TTS onbellegi: %1  %2/%3 sayfa"), state, tostring(done), tostring(total)),
        start_page = tonumber(gen.start_page) or 0,
        end_page = tonumber(gen.end_page) or 0,
        page = page,
        percent = percent,
        label = label,
        skipped = tonumber(gen.skipped) or 0,
        pct = pct,
        errors = tonumber(gen.errors) or 0,
    }
end

function TTSReaderGenerationBar:onTapTTSReaderGenerationBar(_, ges)
    local pos = ges and ges.pos
    local hit = self.stop_hitbox
    if not pos then
        return false
    end
    local rect = self:_barRect()
    if pos.x < rect.x or pos.x > rect.x + rect.w or pos.y < rect.y or pos.y > rect.y + rect.h then
        return false
    end
    if hit and pos.x >= hit.x and pos.x <= hit.x + hit.w and pos.y >= hit.y and pos.y <= hit.y + hit.h then
        if self.owner then
            self.owner:stopGeneration()
        end
        return true
    end
    return true
end

function TTSReaderGenerationBar:resetLayout()
    self:_updateGestureRange()
end

function TTSReaderGenerationBar:paintTo(bb)
    self:_updateGestureRange()
    local snapshot = self:_snapshot()
    if not snapshot then
        self.stop_hitbox = nil
        return
    end

    local rect = self:_barRect()
    self.dimen = rect
    local content_x = rect.x + self.margin
    local content_y = rect.y + 5
    local content_w = rect.w - self.margin * 2
    local content_h = rect.h - 10
    local pad = self.padding
    local face = Font:getFace("smallinfofont", 17)
    local face_bold = Font:getFace("smallinfofont", 18)
    local button_x = content_x + content_w - self.button_w - pad
    local button_y = content_y + math.floor((content_h - self.button_h) / 2)
    local text_w = button_x - content_x - pad * 2
    local progress_x = content_x + pad
    local progress_y = content_y + content_h - self.progress_h - 12
    local progress_w = text_w

    bb:paintRect(content_x, content_y, content_w, content_h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(content_x, content_y, content_w, content_h, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(content_x, content_y, content_w, 3, Blitbuffer.COLOR_BLACK)
    self:_drawText(bb, snapshot.title, face_bold, content_x + pad, content_y + 12, text_w, true)
    local detail = T("P%1-%2  Now %3  %4%", tostring(snapshot.start_page), tostring(snapshot.end_page), tostring(snapshot.page), tostring(snapshot.percent))
    if snapshot.skipped > 0 then
        detail = detail .. T("  R%1", tostring(snapshot.skipped))
    end
    if snapshot.errors > 0 then
        detail = detail .. T("  E%1", tostring(snapshot.errors))
    end
    self:_drawText(bb, detail, face, content_x + pad, content_y + 50, text_w, false, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(progress_x, progress_y, progress_w, self.progress_h, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(progress_x, progress_y, math.max(2, math.floor(progress_w * snapshot.pct)), self.progress_h, Blitbuffer.COLOR_BLACK)

    bb:paintRect(button_x, button_y, self.button_w, self.button_h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(button_x, button_y, self.button_w, self.button_h, 1, Blitbuffer.COLOR_BLACK)
    self:_drawCenteredText(bb, _("Stop"), face, button_x + 6, button_y + 10, self.button_w - 12, false)
    self.stop_hitbox = {
        x = button_x,
        y = button_y,
        w = self.button_w,
        h = self.button_h,
    }
end

function TTSReaderPlayerBar:init()
    self.ges_events.TapTTSReaderPlayerBar = {
        GestureRange:new{
            ges = "tap",
            range = self:_barRect(),
        },
    }
    self.key_events.TTSHeadsetPlayPause = {
        { "HeadsetPlayPause" },
        { "HeadsetPlay" },
        { "HeadsetPause" },
        { "HeadsetMute" },
    }
    self.key_events.TTSHeadsetVolumeDown = { { "HeadsetVolumeDown" } }
    self.key_events.TTSHeadsetVolumeUp = { { "HeadsetVolumeUp" } }
    self.key_events.TTSHeadsetPrevious = { { "HeadsetPrevious" } }
    self.key_events.TTSHeadsetNext = { { "HeadsetNext" } }
    self.key_events.TTSHeadsetStop = { { "HeadsetStop" } }
end

function TTSReaderPlayerBar:_barHeight()
    local min_h = Screen:getHeight() > Screen:getWidth() and self.bar_height or 376
    return math.max(min_h, math.floor(Screen:getHeight() * 0.115))
end

function TTSReaderPlayerBar:_bottomOffset()
    local owner = self.owner
    if owner and owner.generation and owner.generation.active then
        return owner:_generationBarHeight()
    end
    return 0
end

function TTSReaderPlayerBar:_barRect()
    local h = self:_barHeight()
    local offset = self:_bottomOffset()
    return Geom:new{
        x = 0,
        y = math.max(0, Screen:getHeight() - offset - h),
        w = Screen:getWidth(),
        h = h,
    }
end

function TTSReaderPlayerBar:_dynamicRect(rect)
    local top = 7
    return Geom:new{
        x = rect.x,
        y = rect.y + top,
        w = rect.w,
        h = math.min(174, rect.h - top),
    }
end

function TTSReaderPlayerBar:_updateGestureRange()
    local event = self.ges_events and self.ges_events.TapTTSReaderPlayerBar
    if event and event[1] then
        event[1].range = self:_barRect()
    end
end

function TTSReaderPlayerBar:getSize()
    return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

function TTSReaderPlayerBar:_drawText(bb, text, face, x, y, max_width, bold, color)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = bold == true,
        max_width = max_width,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
    }
    widget:paintTo(bb, x, y)
    local size = widget:getSize()
    widget:free()
    return size
end

function TTSReaderPlayerBar:_drawCenteredText(bb, text, face, x, y, width, bold, color, height)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = bold == true,
        max_width = width,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
    }
    local size = widget:getSize()
    local text_x = x + math.max(0, math.floor((width - size.w) / 2))
    local text_y = y
    if height then
        text_y = y + math.max(0, math.floor((height - size.h) / 2))
    end
    widget:paintTo(bb, text_x, text_y)
    widget:free()
    return size
end

function TTSReaderPlayerBar:_drawButton(bb, button, face, x, y, width, height, active)
    local bg = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, width, height, bg)
    bb:paintBorder(x, y, width, height, active and 3 or 2, Blitbuffer.COLOR_BLACK)
    self:_drawCenteredText(bb, button.label, face, x + 6, y, width - 12, true, fg, height)
end

function TTSReaderPlayerBar:_drawButtonRow(bb, buttons, face, x, y, width, height, gap)
    if #buttons == 0 then
        return
    end
    local weight_total = 0
    for button_index, button in ipairs(buttons) do
        weight_total = weight_total + (button.weight or 1)
    end
    local available = width - gap * (#buttons - 1)
    local button_x = x
    for i, button in ipairs(buttons) do
        local button_w
        if i == #buttons then
            button_w = x + width - button_x
        else
            button_w = math.floor(available * (button.weight or 1) / weight_total)
        end
        self:_drawButton(bb, button, face, button_x, y, button_w, height, button.active)
        button_x = button_x + button_w + gap
    end
end

function TTSReaderPlayerBar:_registerButtonRowHitboxes(buttons, x, y, width, height, gap, hitboxes)
    if #buttons == 0 then
        return hitboxes
    end
    hitboxes = hitboxes or self.hitboxes or {}
    local weight_total = 0
    for button_index, button in ipairs(buttons) do
        weight_total = weight_total + (button.weight or 1)
    end
    local available = width - gap * (#buttons - 1)
    local button_x = x
    for i, button in ipairs(buttons) do
        local button_w
        if i == #buttons then
            button_w = x + width - button_x
        else
            button_w = math.floor(available * (button.weight or 1) / weight_total)
        end
        hitboxes[#hitboxes + 1] = {
            id = button.id,
            x = button_x,
            y = y,
            w = button_w,
            h = height,
        }
        button_x = button_x + button_w + gap
    end
    return hitboxes
end

function TTSReaderPlayerBar:_snapshot()
    local owner = self.owner
    local playback = owner and owner.playback
    if not playback or not playback.active then
        return nil
    end

    local entry = playback.current_entry or {}
    local meta = entry.meta or {}
    local total_lines = tonumber(meta.total_lines) or #(playback.page_lines or {})
    local current_line = playback.current_line or owner:_currentPlaybackLine() or tonumber(meta.first_line) or 0
    local pct
    if total_lines > 0 and current_line > 0 then
        pct = current_line / total_lines
    else
        local segment_count = playback.segment_entries and #playback.segment_entries or 1
        pct = (playback.segment_index or 1) / math.max(segment_count, 1)
    end

    local state
    if playback.ready_to_play or not playback.pid then
        state = _("Hazir")
    elseif playback.paused then
        state = _("Durdu")
    else
        state = _("Okuyor")
    end

    local line = playback.page_lines and playback.page_lines[current_line] or ""
    local visible_page = owner:_visiblePage()
    local page_drift = Engine.playbackPageDrift(visible_page, playback.page)
    local page_prefix = page_drift
        and T(_("Ses %1  Ekran %2"), tostring(playback.page), tostring(page_drift.current_page))
        or T(_("Ses %1"), tostring(playback.page))
    return {
        state = state,
        detail = total_lines > 0 and current_line > 0
            and T(_("%1  Satir %2/%3"), page_prefix, tostring(current_line), tostring(total_lines))
            or T(_("%1  Bolum %2"), page_prefix, tostring(playback.segment_index or 1)),
        line = shortLine(line),
        pct = clamp(pct, 0, 1),
        speed = Engine.speedLabel(playback.speed or 1),
        volume = Engine.volumeLabel(playback.volume or owner:_playbackVolume()),
        bluetooth = Engine.bluetoothStatusLabel(playback.bluetooth_status),
        page_drift = page_drift,
        play_label = playback.pid and (playback.paused and _("Devam") or _("Duraklat")) or _("Oynat"),
    }
end

function TTSReaderPlayerBar:_primaryButtons(snapshot)
    return {
        { id = "back", label = "-15 sn", weight = 0.9 },
        { id = "play", label = snapshot.play_label, weight = 1.75, active = not snapshot.page_drift },
        { id = "fwd", label = "+15 sn", weight = 0.9 },
        { id = "volume_down", label = "V-", weight = 0.85 },
        { id = "volume", label = snapshot.volume, weight = 1.2 },
        { id = "volume_up", label = "V+", weight = 0.85 },
        { id = "speed", label = snapshot.speed, weight = 0.9 },
        { id = "stop", label = _("Dur"), weight = 0.9 },
    }
end

function TTSReaderPlayerBar:_primaryButtonRows(snapshot)
    if Screen:getHeight() <= Screen:getWidth() then
        return { self:_primaryButtons(snapshot) }
    end
    return {
        {
            { id = "back", label = "-15 sn", weight = 0.9 },
            { id = "play", label = snapshot.play_label, weight = 1.7, active = not snapshot.page_drift },
            { id = "fwd", label = "+15 sn", weight = 0.9 },
            { id = "speed", label = snapshot.speed, weight = 0.85 },
            { id = "stop", label = _("Dur"), weight = 0.85 },
        },
        {
            { id = "volume_down", label = "V-", weight = 1 },
            { id = "volume", label = snapshot.volume, weight = 1.35 },
            { id = "volume_up", label = "V+", weight = 1 },
        },
    }
end

function TTSReaderPlayerBar:_contextButtons(snapshot)
    if snapshot.page_drift then
        return {
            { id = "current_page", label = _("Bu sayfadan devam"), weight = 2, active = true },
            { id = "page", label = _("Ses sayfasina don"), weight = 1 },
        }
    end
    return {
        { id = "page", label = _("Ses sayfasi"), weight = 1 },
    }
end

function TTSReaderPlayerBar:_layout(rect, snapshot)
    local pad = self.padding
    local content_x = rect.x + self.margin
    local content_y = rect.y
    local content_w = rect.w - self.margin * 2
    local content_h = rect.h
    local text_w = content_w - pad * 2
    local button_gap = 10
    local button_rows = self:_primaryButtonRows(snapshot)
    local controls_gap = 12
    local controls_h = #button_rows * self.button_h + math.max(0, #button_rows - 1) * controls_gap
    return {
        content_x = content_x,
        content_y = content_y,
        content_w = content_w,
        content_h = content_h,
        controls_w = text_w,
        text_w = text_w,
        pad = pad,
        button_gap = button_gap,
        top_y = content_y + 18,
        state_w = math.max(126, math.floor(content_w * 0.13)),
        line_y = content_y + 98,
        progress_x = content_x + pad,
        progress_y = content_y + 154,
        progress_w = text_w,
        context_y = content_y + 188,
        primary_rows = button_rows,
        context_buttons = self:_contextButtons(snapshot),
        controls_gap = controls_gap,
        controls_y = content_y + content_h - controls_h - self.controls_bottom_inset,
    }
end

function TTSReaderPlayerBar:_staticCacheKey(snapshot, rect, bb_type)
    local drift = snapshot.page_drift and (tostring(snapshot.page_drift.current_page) .. ":" .. tostring(snapshot.page_drift.audio_page)) or "same"
    return table.concat({
        tostring(rect.x),
        tostring(rect.y),
        tostring(rect.w),
        tostring(rect.h),
        tostring(bb_type or ""),
        snapshot.play_label or "",
        snapshot.speed or "",
        snapshot.volume or "",
        drift,
    }, "|")
end

function TTSReaderPlayerBar:_paintStaticLayer(bb, snapshot, layout, dx, dy, faces)
    local content_x = layout.content_x - dx
    local content_y = layout.content_y - dy
    local pad = layout.pad
    bb:paintRect(0, 0, layout.content_w, layout.content_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(content_x, content_y, layout.content_w, layout.content_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, 0, layout.content_w, 7, Blitbuffer.COLOR_BLACK)

    self:_drawButtonRow(
        bb,
        layout.context_buttons,
        faces.small_button,
        content_x + pad,
        layout.context_y - dy,
        layout.controls_w,
        self.small_button_h,
        layout.button_gap
    )

    for row_idx, buttons in ipairs(layout.primary_rows) do
        local row_y = layout.controls_y + (row_idx - 1) * (self.button_h + layout.controls_gap)
        self:_drawButtonRow(
            bb,
            buttons,
            faces.button,
            content_x + pad,
            row_y - dy,
            layout.controls_w,
            self.button_h,
            layout.button_gap
        )
    end
end

function TTSReaderPlayerBar:_ensureStaticCache(target_bb, snapshot, rect, layout, faces, cache_key)
    local bb_type = target_bb:getType()
    local key = cache_key or self:_staticCacheKey(snapshot, rect, bb_type)
    if self.static_bb and self.static_cache_key == key then
        return
    end
    if self.static_bb then
        self.static_bb:free()
    end
    self.static_bb = Blitbuffer.new(rect.w, rect.h, bb_type)
    self.static_cache_key = key
    self.static_layout = layout
    self.static_hitboxes = self:_registerLayoutHitboxes(layout, {})
    self:_paintStaticLayer(self.static_bb, snapshot, layout, rect.x, rect.y, faces)
end

function TTSReaderPlayerBar:_paintDynamicLayer(bb, snapshot, layout, dx, dy, faces)
    local content_x = layout.content_x - dx
    local pad = layout.pad
    local top_y = layout.top_y - dy
    local state_x = content_x + pad
    bb:paintRect(state_x, top_y, layout.state_w, 48, Blitbuffer.COLOR_BLACK)
    self:_drawCenteredText(bb, snapshot.state, faces.state, state_x, top_y, layout.state_w, true, Blitbuffer.COLOR_WHITE, 48)

    local title_x = state_x + layout.state_w + 16
    local title_w = layout.text_w - layout.state_w - 16
    local title = snapshot.detail .. "  " .. snapshot.speed
    if snapshot.bluetooth then
        title = title .. "  " .. Engine.bluetoothHeaderLabel(snapshot.bluetooth)
    end
    self:_drawText(bb, title, faces.title, title_x, top_y + 8, title_w, true)

    local line_y = layout.line_y - dy
    bb:paintRect(content_x + pad, line_y - 8, layout.text_w, 50, Blitbuffer.COLOR_GRAY_E)
    if snapshot.line ~= "" then
        bb:paintRect(content_x + pad + 8, line_y, 5, 30, Blitbuffer.COLOR_BLACK)
    end
    self:_drawText(bb, snapshot.line ~= "" and snapshot.line or _("Satir bilgisi hazirlaniyor"), faces.line, content_x + pad + 24, line_y - 1, layout.text_w - 32, false, Blitbuffer.COLOR_BLACK)

    local progress_x = layout.progress_x - dx
    local progress_y = layout.progress_y - dy
    bb:paintRect(progress_x, progress_y, layout.progress_w, self.progress_h, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(progress_x, progress_y, math.max(2, math.floor(layout.progress_w * snapshot.pct)), self.progress_h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(progress_x, progress_y - 2, layout.progress_w, 1, Blitbuffer.COLOR_GRAY)
    bb:paintRect(progress_x, progress_y + self.progress_h + 1, layout.progress_w, 1, Blitbuffer.COLOR_GRAY)
end

function TTSReaderPlayerBar:_registerLayoutHitboxes(layout, hitboxes)
    hitboxes = hitboxes or {}
    self:_registerButtonRowHitboxes(
        layout.context_buttons,
        layout.content_x + layout.pad,
        layout.context_y,
        layout.controls_w,
        self.small_button_h,
        layout.button_gap,
        hitboxes
    )
    for row_idx, buttons in ipairs(layout.primary_rows) do
        local row_y = layout.controls_y + (row_idx - 1) * (self.button_h + layout.controls_gap)
        self:_registerButtonRowHitboxes(
            buttons,
            layout.content_x + layout.pad,
            row_y,
            layout.controls_w,
            self.button_h,
            layout.button_gap,
            hitboxes
        )
    end
    return hitboxes
end

function TTSReaderPlayerBar:freeCache()
    if self.static_bb then
        self.static_bb:free()
        self.static_bb = nil
    end
    self.static_cache_key = nil
    self.static_layout = nil
    self.static_hitboxes = nil
end

function TTSReaderPlayerBar:_runAction(id)
    local owner = self.owner
    if not owner then
        return
    end
    if id == "back" then
        owner:seekPlayback(-15)
    elseif id == "play" then
        owner:togglePlaybackPause()
    elseif id == "fwd" then
        owner:seekPlayback(15)
    elseif id == "volume_down" then
        owner:adjustPlaybackVolume(-1)
    elseif id == "volume" then
        owner:adjustPlaybackVolume(1)
    elseif id == "volume_up" then
        owner:adjustPlaybackVolume(1)
    elseif id == "speed" then
        owner:cyclePlaybackSpeed()
    elseif id == "page" then
        owner:goToPlaybackPage()
    elseif id == "current_page" then
        owner:continuePlaybackFromVisiblePage()
    elseif id == "stop" then
        owner:stopPlayback(false)
    end
end

function TTSReaderPlayerBar:onTTSHeadsetPlayPause()
    self:_runAction("play")
    return true
end

function TTSReaderPlayerBar:onTTSHeadsetVolumeDown()
    self:_runAction("volume_down")
    return true
end

function TTSReaderPlayerBar:onTTSHeadsetVolumeUp()
    self:_runAction("volume_up")
    return true
end

function TTSReaderPlayerBar:onTTSHeadsetPrevious()
    self:_runAction("back")
    return true
end

function TTSReaderPlayerBar:onTTSHeadsetNext()
    self:_runAction("fwd")
    return true
end

function TTSReaderPlayerBar:onTTSHeadsetStop()
    self:_runAction("stop")
    return true
end

function TTSReaderPlayerBar:onTapTTSReaderPlayerBar(_, ges)
    local pos = ges and ges.pos
    if not pos then
        return false
    end
    local rect = self:_barRect()
    if pos.x < rect.x or pos.x > rect.x + rect.w or pos.y < rect.y or pos.y > rect.y + rect.h then
        return false
    end
    for hit_index, hit in ipairs(self.hitboxes or {}) do
        if pos.x >= hit.x and pos.x <= hit.x + hit.w and pos.y >= hit.y and pos.y <= hit.y + hit.h then
            self:_runAction(hit.id)
            return true
        end
    end
    return true
end

function TTSReaderPlayerBar:resetLayout()
    self:_updateGestureRange()
end

function TTSReaderPlayerBar:paintTo(bb)
    self:_updateGestureRange()
    local snapshot = self:_snapshot()
    if not snapshot then
        self.hitboxes = {}
        return
    end

    local rect = self:_barRect()
    self.dimen = rect
    local faces = {
        state = Font:getFace("smallinfofont", 18),
        title = Font:getFace("smallinfofont", 19),
        line = Font:getFace("smallinfofont", 18),
        button = Font:getFace("smallinfofont", 21),
        small_button = Font:getFace("smallinfofont", 18),
    }
    local cache_key = self:_staticCacheKey(snapshot, rect, bb:getType())
    local layout = self.static_cache_key == cache_key and self.static_layout
        or self:_layout(rect, snapshot)
    self:_ensureStaticCache(bb, snapshot, rect, layout, faces, cache_key)
    layout = self.static_layout or layout
    self.hitboxes = self.static_hitboxes or self:_registerLayoutHitboxes(layout, {})
    bb:blitFrom(self.static_bb, rect.x, rect.y, 0, 0, rect.w, rect.h)
    self:_paintDynamicLayer(bb, snapshot, layout, 0, 0, faces)
end

function TTSReader:init()
    self.settings = Engine.openSettings()
    self.config = Engine.readConfig(self.settings)
    local saved_config = self.settings.data.google_tts or {}
    if saved_config.audio_encoding ~= self.config.audio_encoding then
        Engine.saveConfig(self.settings, self.config)
    end
    self.ui.menu:registerToMainMenu(self)
    self:_scheduleBluetoothIdleShutdown()
end

function TTSReader:_headsetTrackedInputCount()
    local count = 0
    for _ in pairs(self.headset_input_paths or {}) do
        count = count + 1
    end
    return count
end

function TTSReader:_refreshHeadsetInputReady()
    local first_path
    for path in pairs(self.headset_input_paths or {}) do
        first_path = first_path or path
    end
    self.headset_input_path = first_path
    self.headset_input_ready = first_path ~= nil
    return self.headset_input_ready
end

function TTSReader:_closeHeadsetInputPath(path)
    if Device.input and Device.input.close then
        pcall(function()
            Device.input:close(path)
        end)
    end
end

function TTSReader:_ensureHeadsetInputOpen()
    local now = socket.gettime()
    if self.headset_input_ready
        and self.headset_input_paths
        and self:_headsetTrackedInputCount() > 0
        and self.headset_input_last_validate
        and now - self.headset_input_last_validate < 2
    then
        return true
    end
    self.headset_input_last_validate = now

    local current_paths = avrcpInputDevicePaths()
    self.headset_input_paths = self.headset_input_paths or {}
    for path in pairs(self.headset_input_paths) do
        if not current_paths[path] or not fileExists(path) then
            self:_closeHeadsetInputPath(path)
            self.headset_input_paths[path] = nil
        end
    end

    if self.headset_input_last_scan
        and now - self.headset_input_last_scan < 3
        and self:_headsetTrackedInputCount() == 0
    then
        self:_refreshHeadsetInputReady()
        return false
    end
    self.headset_input_last_scan = now

    if not Device.input or not Device.input.open then
        return self:_refreshHeadsetInputReady()
    end
    for device_index, device in ipairs(avrcpInputDevices()) do
        if fileExists(device.path) and not self.headset_input_paths[device.path] then
            local ok, err = pcall(function()
                return Device.input:open(device.path, device.name)
            end)
            if ok then
                self.headset_input_paths[device.path] = device.name or true
                logger.info("ttsreader headset AVRCP input ready:", device.name, device.path)
            else
                logger.warn("ttsreader could not open AVRCP input:", device.path, err)
            end
        end
    end
    return self:_refreshHeadsetInputReady()
end

function TTSReader:_headsetInputBarRefreshNeeded(has_existing_bar)
    if not has_existing_bar then
        return true
    end
    local last_validate = tonumber(self.headset_input_last_validate)
    if not last_validate then
        return true
    end
    local interval = self.headset_input_ready
        and self.headset_input_bar_validate_interval
        or self.headset_input_missing_scan_interval
    return socket.gettime() - last_validate >= interval
end

function TTSReader:_scheduleHeadsetInputOpen(delay)
    UIManager:scheduleIn(tonumber(delay) or 0.5, function()
        self.headset_input_last_scan = nil
        self.headset_input_last_validate = nil
        self:_ensureHeadsetInputOpen()
    end)
end

function TTSReader:_scheduleHeadsetInputRefreshBurst()
    if not self:_hasBluetoothAudio() then
        return
    end
    local now = socket.gettime()
    if self.headset_input_ready
        and self.headset_input_last_validate
        and now - self.headset_input_last_validate < 2
    then
        return
    end
    if self.headset_input_refresh_started_at
        and now - self.headset_input_refresh_started_at < 20
    then
        return
    end
    self.headset_input_refresh_started_at = now
    self.headset_input_refresh_token = (self.headset_input_refresh_token or 0) + 1
    local token = self.headset_input_refresh_token
    for _idx, delay in ipairs({ 0.25, 0.8, 1.8, 3.6, 5.5, 8.5, 12.5, 18.0 }) do
        UIManager:scheduleIn(delay, function()
            if self.headset_input_refresh_token ~= token then
                return
            end
            self.headset_input_last_scan = nil
            self.headset_input_last_validate = nil
            if self:_ensureHeadsetInputOpen() then
                self.headset_input_refresh_token = nil
            end
        end)
    end
end

function TTSReader:onEvdevInputInsert(path)
    if not path or not path:match("^/dev/input/event%d+$") then
        return
    end
    self.headset_input_ready = false
    self.headset_input_path = nil
    self.headset_input_last_validate = nil
    self.headset_input_last_scan = nil
    if self.playback and self.playback.active then
        self:_scheduleHeadsetInputOpen(0.5)
    end
end

function TTSReader:onEvdevInputRemove(path)
    if path and self.headset_input_paths and self.headset_input_paths[path] then
        self.headset_input_paths[path] = nil
        self:_refreshHeadsetInputReady()
        self.headset_input_last_scan = nil
        self.headset_input_last_validate = nil
    end
end

function TTSReader:onCloseWidget()
    self:stopGeneration(false)
    self:stopPlayback(false)
    self:stopKeyServer(false)
end

function TTSReader:onPrepareUSBMS()
    self:stopGeneration(false)
    self:stopPlayback(false)
    self:stopKeyServer(false)
    os.execute("killall -q -TERM ttsreader-play 2>/dev/null || true")
end

function TTSReader:onCloseDocument()
    self:stopGeneration(false)
    self:stopPlayback(false)
end

function TTSReader:_show(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 4,
    })
end

function TTSReader:_hasDocument()
    return self.ui and self.ui.document
end

function TTSReader:_bookTitle()
    return self.ui.doc_props and self.ui.doc_props.display_title or _("Current book")
end

function TTSReader:_narrationVoice()
    if not self:_hasDocument() or not self.ui.doc_settings then
        return nil
    end
    return Engine.narrationVoice(self.ui.doc_settings:readSetting("ttsreader_narration_voice"))
end

function TTSReader:_narrationConfig()
    local voice = self:_narrationVoice()
    if not voice then
        return self.config
    end
    local config = {}
    for key, value in pairs(self.config) do
        config[key] = value
    end
    config.language_code = voice.language_code
    config.voice_name = voice.voice_name
    return config
end

function TTSReader:_narrationLanguageLabel()
    local voice = self:_narrationVoice()
    if not voice then
        return _("Secilmedi")
    end
    return voice.id == "tr" and _("Turkce") or _("English")
end

function TTSReader:_setNarrationVoice(id, callback)
    local voice = Engine.narrationVoice(id)
    if not voice or not self:_hasDocument() or not self.ui.doc_settings then
        return
    end
    self:stopGeneration(false)
    self:stopPlayback(false)
    self.ui.doc_settings:saveSetting("ttsreader_narration_voice", id)
    self.ui.doc_settings:flush()
    if callback then
        callback()
    else
        self:_show(T(_("Seslendirme dili: %1"), self:_narrationLanguageLabel()))
    end
end

function TTSReader:chooseNarrationLanguage(callback)
    if not self:_hasDocument() then
        self:_show(_("Open a book first."))
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = _("Seslendirme dili"),
        width = math.floor(Screen:getWidth() * 0.92),
        buttons = {
            {
                {
                    text = _("Turkce"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_setNarrationVoice("tr", callback)
                    end,
                },
                {
                    text = _("English"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_setNarrationVoice("en", callback)
                    end,
                },
            },
            {
                {
                    text = _("Vazgec"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function TTSReader:_bookDir()
    local voice = self:_narrationVoice()
    local variant
    if voice and (voice.language_code ~= self.config.language_code or voice.voice_name ~= self.config.voice_name) then
        variant = Engine.narrationVoiceCacheKey(voice)
    end
    return Engine.bookCacheDir(self.ui.document.file, self:_bookTitle(), variant)
end

function TTSReader:_currentPage()
    if self.ui.getCurrentPage then
        return self.ui:getCurrentPage()
    end
    if self.ui.paging then
        return self.ui.paging.current_page
    end
    return self.ui.document:getCurrentPage()
end

function TTSReader:_visiblePage()
    if not self:_hasDocument() then
        return nil
    end
    local ok, page = pcall(function()
        return self:_currentPage()
    end)
    page = ok and tonumber(page) or nil
    if not page or page < 1 then
        return nil
    end
    return math.floor(page)
end

function TTSReader:_pageCount()
    if self.ui.document and self.ui.document.getPageCount then
        return self.ui.document:getPageCount()
    end
    return self.ui.document.info and self.ui.document.info.number_of_pages or 1
end

function TTSReader:_refreshConfig()
    self.settings = Engine.openSettings()
    self.config = Engine.readConfig(self.settings)
end

function TTSReader:_saveConfig()
    Engine.saveConfig(self.settings, self.config)
end

function TTSReader:_localEndpoint()
    local udp = socket.udp()
    if udp then
        udp:setpeername("8.8.8.8", 80)
        local ip = udp:getsockname()
        udp:close()
        if ip and ip ~= "0.0.0.0" then
            return string.format("%s:%d", ip, self.key_server_port)
        end
    end
    return string.format("kobo.local:%d", self.key_server_port)
end

function TTSReader:_newKeyServerPassword()
    local seed = table.concat({
        tostring(socket.gettime()),
        tostring(os.time()),
        tostring({}),
        tostring(self),
    }, "|")
    local number = tonumber(sha2.sha1(seed):sub(1, 8), 16) or os.time()
    return string.format("%06d", number % 1000000)
end

function TTSReader:_keyServerInstruction()
    return T(
        _("Address:\n%1\n\nOne-time password:\n%2"),
        self:_localEndpoint(),
        self.key_server_password or ""
    )
end

function TTSReader:startKeyServer()
    if self.key_server then
        self:_show(self:_keyServerInstruction(), 14)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local server, err = socket.bind("*", self.key_server_port)
        if not server then
            self:_show(T(_("Could not start API key server: %1"), tostring(err)), 8)
            return
        end
        self.key_server_password = self:_newKeyServerPassword()
        server:settimeout(0)
        self.key_server = server
        self.key_server_task = function()
            self:_pollKeyServer()
        end
        UIManager:scheduleIn(0.1, self.key_server_task)
        self:_show(self:_keyServerInstruction(), 14)
    end)
end

function TTSReader:stopKeyServer(show_message)
    if self.key_server_task then
        UIManager:unschedule(self.key_server_task)
        self.key_server_task = nil
    end
    if self.key_server then
        self.key_server:close()
        self.key_server = nil
        self.key_server_password = nil
        if show_message ~= false then
            self:_show(_("API key server stopped."))
        end
    end
end

function TTSReader:_keyServerPage()
    local cfg = self.config
    local voice = Engine.htmlEscape(cfg.voice_name or Engine.defaults.voice_name)
    local language = Engine.htmlEscape(cfg.language_code or Engine.defaults.language_code)
    local masked = Engine.htmlEscape(Engine.maskSecret(cfg.api_key))
    return [[<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kobo TTS</title><style>body{font:16px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;max-width:560px;margin:32px auto;padding:0 18px;line-height:1.45;color:#111;background:#f7f7f4}h1{font-size:24px;margin:0 0 18px}label{display:block;margin:14px 0 6px;font-weight:650}input,button{font:inherit;width:100%;box-sizing:border-box;padding:13px 12px;border:1px solid #222;background:#fff}button{margin-top:16px;font-weight:750;background:#111;color:#fff}small{color:#444;display:block;margin:7px 0 4px}.secondary button{background:#fff;color:#111}</style></head><body><h1>Kobo TTS</h1><form method="post" action="/save"><label>One-time password</label><input name="setup_password" value="" type="password" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" placeholder="Code shown on Kobo"><label>Google API key</label><input name="api_key" value="" placeholder="]] .. masked .. [[" autocomplete="off"><small>Leave blank to keep the saved key.</small><label>Voice</label><input name="voice_name" value="]] .. voice .. [["><label>Language</label><input name="language_code" value="]] .. language .. [["><button type="submit">Save and stop server</button></form><form class="secondary" method="post" action="/stop"><label>One-time password</label><input name="setup_password" value="" type="password" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" placeholder="Code shown on Kobo"><button type="submit">Stop without saving</button></form></body></html>]]
end

function TTSReader:_passwordMatches(password)
    return password and self.key_server_password and password == self.key_server_password
end

function TTSReader:_httpSend(client, status, content_type, body)
    body = body or ""
    client:send(table.concat({
        "HTTP/1.1 " .. status,
        "Connection: close",
        "Content-Type: " .. content_type,
        "Content-Length: " .. tostring(#body),
        "",
        body,
    }, "\r\n"))
end

function TTSReader:_handleKeyRequest(client)
    client:settimeout(1)
    local request_line = client:receive("*l")
    if not request_line then
        client:close()
        return
    end
    local method, path = request_line:match("^(%S+)%s+(%S+)")
    path = (path or "/"):match("^([^?]*)") or "/"
    local headers = {}
    while true do
        local line = client:receive("*l")
        if not line or line == "" then
            break
        end
        local key, value = line:match("^([^:]+):%s*(.*)$")
        if key then
            headers[key:lower()] = value
        end
    end

    if method == "POST" and path == "/save" then
        local length = tonumber(headers["content-length"]) or 0
        local body = length > 0 and client:receive(length) or ""
        local form = Engine.parseFormEncoded(body)
        if not self:_passwordMatches(form.setup_password) then
            self:_httpSend(client, "403 Forbidden", "text/plain; charset=utf-8", "Bad one-time password")
            client:close()
            return
        end
        if form.api_key and form.api_key ~= "" then
            self.config.api_key = form.api_key
        end
        if form.voice_name and form.voice_name ~= "" then
            self.config.voice_name = form.voice_name
        end
        if form.language_code and form.language_code ~= "" then
            self.config.language_code = form.language_code
        end
        self:_saveConfig()
        self:_httpSend(client, "200 OK", "text/html; charset=utf-8", "<html><body><h1>Saved</h1><p>You can close this page.</p></body></html>")
        client:close()
        UIManager:scheduleIn(0.1, function()
            self:stopKeyServer(false)
            self:_show(_("Google TTS settings saved."))
        end)
        return
    elseif method == "POST" and path == "/stop" then
        local length = tonumber(headers["content-length"]) or 0
        local body = length > 0 and client:receive(length) or ""
        local form = Engine.parseFormEncoded(body)
        if not self:_passwordMatches(form.setup_password) then
            self:_httpSend(client, "403 Forbidden", "text/plain; charset=utf-8", "Bad one-time password")
            client:close()
            return
        end
        self:_httpSend(client, "200 OK", "text/html; charset=utf-8", "<html><body><h1>Stopped</h1></body></html>")
        client:close()
        UIManager:scheduleIn(0.1, function()
            self:stopKeyServer(false)
        end)
        return
    end

    if method == "GET" and path == "/" then
        self:_httpSend(client, "200 OK", "text/html; charset=utf-8", self:_keyServerPage())
    else
        self:_httpSend(client, "404 Not Found", "text/plain; charset=utf-8", "Open the address shown on your Kobo.")
    end
    client:close()
end

function TTSReader:_pollKeyServer()
    if not self.key_server then
        return
    end
    local client = self.key_server:accept()
    if client then
        local ok, err = pcall(function()
            self:_handleKeyRequest(client)
        end)
        if not ok then
            logger.warn("ttsreader key server request failed:", err)
            pcall(function() client:close() end)
        end
    end
    if self.key_server_task then
        UIManager:scheduleIn(0.2, self.key_server_task)
    end
end

function TTSReader:_synthesize(input)
    local want_timepoints = type(input) == "table" and input.enable_timepoints
    local api_version = want_timepoints and "v1beta1" or "v1"
    local body = Engine.googleRequestJSON(input, self:_narrationConfig())
    local response = {}
    local url = "https://texttospeech.googleapis.com/" .. api_version .. "/text:synthesize?key=" .. socket_url.escape(self.config.api_key or "")
    socketutil:set_timeout(20, 90)
    local code, _, status = socket.skip(1, https.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["User-Agent"] = socketutil.USER_AGENT,
        },
        source = ltn12.source.string(body),
        sink = socketutil.table_sink(response),
    })
    socketutil:reset_timeout()

    local content = table.concat(response)
    if code ~= 200 then
        return nil, T(_("Google TTS failed: HTTP %1 %2"), tostring(code), tostring(status or ""))
    end

    local ok, decoded = pcall(rapidjson.decode, content)
    if not ok or type(decoded) ~= "table" or type(decoded.audioContent) ~= "string" then
        return nil, _("Google TTS returned an invalid response.")
    end
    return sha2.base64_to_bin(decoded.audioContent), nil, Engine.timepointsByLine(decoded.timepoints)
end

function TTSReader:_synthesizeWorkerScript()
    return [[
local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a") or ""
    file:close()
    return data
end

local function write_file(path, data, mode)
    local file = assert(io.open(path, mode or "wb"))
    file:write(data or "")
    file:close()
end

local request_path = assert(arg[1], "missing request path")
local key_path = assert(arg[2], "missing key path")
local api_version = assert(arg[3], "missing api version")
local audio_path = assert(arg[4], "missing audio path")
local meta_path = assert(arg[5], "missing meta path")

local function finish(ok, err, timepoints)
    local rapidjson = require("rapidjson")
    local payload = { ok = ok == true }
    if err then
        payload.error = tostring(err)
    end
    if timepoints then
        payload.timepoints = timepoints
    end
    write_file(meta_path, rapidjson.encode(payload) .. "\n", "w")
end

local ok, err = pcall(function()
    require("setupkoenv")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local rapidjson = require("rapidjson")
    local sha2 = require("ffi/sha2")
    local socket = require("socket")
    local socket_url = require("socket.url")

    https.TIMEOUT = 90
    local body = read_file(request_path)
    local api_key = read_file(key_path):gsub("%s+$", "")
    if api_key == "" then
        finish(false, "Google API key is not set.")
        os.exit(3)
    end

    local response = {}
    local url = "https://texttospeech.googleapis.com/" .. api_version .. "/text:synthesize?key=" .. socket_url.escape(api_key)
    local code, _, status = socket.skip(1, https.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["User-Agent"] = "KOReader-TTSReader",
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    })

    if code ~= 200 then
        finish(false, "Google TTS failed: HTTP " .. tostring(code) .. " " .. tostring(status or ""))
        os.exit(2)
    end

    local decoded_ok, decoded = pcall(rapidjson.decode, table.concat(response))
    if not decoded_ok or type(decoded) ~= "table" or type(decoded.audioContent) ~= "string" then
        finish(false, "Google TTS returned an invalid response.")
        os.exit(2)
    end

    local audio = sha2.base64_to_bin(decoded.audioContent)
    if type(audio) ~= "string" or #audio == 0 then
        finish(false, "Google TTS returned empty audio.")
        os.exit(2)
    end

    write_file(audio_path, audio, "wb")
    finish(true, nil, decoded.timepoints)
end)

if not ok then
    local meta = io.open(meta_path, "w")
    if meta then
        meta:write('{"ok":false,"error":"TTS worker crashed."}\n')
        meta:close()
    end
    io.stderr:write(tostring(err), "\n")
    os.exit(1)
end
]]
end

function TTSReader:_startSynthesizeJob(input)
    local want_timepoints = type(input) == "table" and input.enable_timepoints
    local api_version = want_timepoints and "v1beta1" or "v1"
    local body = Engine.googleRequestJSON(input, self:_narrationConfig())
    local job = self:_newAsyncJob("synth", 130)
    job.request_path = job.output .. ".request.json"
    job.key_path = job.output .. ".key"
    job.script_path = job.output .. ".lua"
    job.audio_path = job.output .. ".audio"
    job.meta_path = job.output .. ".meta"
    job.extra_files = {
        job.request_path,
        job.key_path,
        job.script_path,
        job.audio_path,
        job.meta_path,
    }

    local ok, err = writeFile(job.request_path, body, "wb")
    if not ok then
        self:_cleanupAsyncJob(job)
        return nil, err
    end
    ok, err = writeFile(job.key_path, self.config.api_key or "", "wb")
    if not ok then
        self:_cleanupAsyncJob(job)
        return nil, err
    end
    ok, err = writeFile(job.script_path, self:_synthesizeWorkerScript(), "w")
    if not ok then
        self:_cleanupAsyncJob(job)
        return nil, err
    end
    os.execute("chmod 600 " .. shellQuote(job.request_path) .. " " .. shellQuote(job.key_path) .. " " .. shellQuote(job.script_path))

    self.koreader_dir = self.koreader_dir or firstLine("pwd") or "."
    local worker_args = table.concat({
        "./luajit",
        shellQuote(job.script_path),
        shellQuote(job.request_path),
        shellQuote(job.key_path),
        shellQuote(api_version),
        shellQuote(job.audio_path),
        shellQuote(job.meta_path),
    }, " ")
    local command = table.concat({
        "cd " .. shellQuote(self.koreader_dir),
        "&& if command -v ionice >/dev/null 2>&1; then exec ionice -c 3 nice -n 19 " .. worker_args
            .. "; elif command -v nice >/dev/null 2>&1; then exec nice -n 19 " .. worker_args
            .. "; else exec " .. worker_args .. "; fi",
    }, " ")
    return self:_launchAsyncJob(job, command)
end

function TTSReader:_pollSynthesizeJob(job, done_callback)
    if not job or job.cancelled then
        return
    end
    local gen = self.generation
    if not gen or gen.synth_job ~= job then
        self:_cancelAsyncJob(job)
        return
    end
    if fileExists(job.done) then
        local status = tonumber((readFile(job.done):match("(%-?%d+)"))) or 1
        local output = readFile(job.output)
        local meta_text = readFile(job.meta_path)
        local ok, meta = pcall(rapidjson.decode, meta_text)
        if status ~= 0 or not ok or type(meta) ~= "table" or meta.ok ~= true then
            local err = ok and type(meta) == "table" and meta.error or shortLine(output)
            self:_cleanupAsyncJob(job)
            done_callback(nil, err or _("Google TTS worker failed."))
            return
        end
        local audio_path = job.audio_path
        if fileSize(audio_path) == 0 then
            self:_cleanupAsyncJob(job)
            done_callback(nil, _("Google TTS worker returned empty audio."))
            return
        end
        local timepoints = Engine.timepointsByLine(meta.timepoints)
        self:_detachAsyncJobExtraFile(job, audio_path)
        job.audio_path = nil
        self:_cleanupAsyncJob(job)
        done_callback(audio_path, nil, timepoints)
        return
    end
    if socket.gettime() - job.started_at > (job.timeout + 3) then
        self:_cancelAsyncJob(job)
        done_callback(nil, _("Google TTS timed out."))
        return
    end
    UIManager:scheduleIn(0.25, function()
        self:_pollSynthesizeJob(job, done_callback)
    end)
end

function TTSReader:_preparePageGeneration(book_dir, page)
    local request_limit = tonumber(self.config.request_char_limit) or Engine.defaults.request_char_limit
    local wrap_limit = request_limit - 96
    local cached_lines = Engine.readPageLines(book_dir, page)
    local lines = Engine.wrapLongLines(
        cached_lines and #cached_lines > 0 and cached_lines or Engine.extractPageLines(self.ui.document, page),
        wrap_limit
    )
    if #lines == 0 then
        Engine.markPageSkipped(book_dir, page, "no extractable text")
        return nil, nil, true
    end
    if not cached_lines or #cached_lines == 0 then
        Engine.writePageLines(book_dir, page, lines)
    end

    local chunks = Engine.buildLineChunks(lines, request_limit)
    if #chunks == 0 then
        Engine.markPageSkipped(book_dir, page, "empty")
        return nil, nil, true
    end

    return {
        book_dir = book_dir,
        page = page,
        lines = lines,
        chunks = chunks,
        index = 1,
        retry_plain = false,
    }
end

function TTSReader:_generatePage(book_dir, page)
    local cache_status = Engine.pageCacheStatus(book_dir, page, self.config)
    if cache_status.state == "complete" or cache_status.state == "skipped" then
        return true
    end

    local ctx, err, skipped = self:_preparePageGeneration(book_dir, page)
    if skipped then
        return true
    end
    if not ctx then
        return false, err
    end

    for i, chunk in ipairs(ctx.chunks) do
        local path = Engine.segmentPath(book_dir, page, i, self.config)
        local meta = Engine.readSegmentMeta(book_dir, page, i)
        if not fileExists(path) or not meta then
            local input
            if self.config.line_timepoints ~= false then
                input = {
                    ssml = Engine.lineChunkSSML(ctx.lines, chunk),
                    enable_timepoints = true,
                }
            else
                input = Engine.lineChunkText(ctx.lines, chunk)
            end
            local audio, err, timepoints = self:_synthesize(input)
            if not audio and type(input) == "table" and input.enable_timepoints then
                logger.warn("ttsreader timepoint synthesis failed on page", page, "segment", i, err, "retrying without timepoints")
                audio, err = self:_synthesize(Engine.lineChunkText(ctx.lines, chunk))
                timepoints = {}
            end
            if not audio then
                return false, err
            end
            local tmp = path .. ".tmp"
            local file = assert(io.open(tmp, "wb"))
            file:write(audio)
            file:close()
            os.rename(tmp, path)
            Engine.writeSegmentMeta(book_dir, page, i, {
                first_line = chunk.first_line,
                last_line = chunk.last_line,
                total_lines = chunk.total_lines,
                timepoints = timepoints or {},
            })
        end
    end
    Engine.markPageDone(book_dir, page, #ctx.chunks)
    return true
end

function TTSReader:_finishGenerationPage(page, ok, err, generated)
    local gen = self.generation
    if not gen or not gen.active then
        return
    end
    gen.synth_job = nil
    gen.next_page = page + 1
    gen.current_page = nil
    if ok then
        gen.done = gen.done + 1
        if generated then
            gen.generated = (tonumber(gen.generated) or 0) + 1
        end
        self:_showGenerationBar(false, false)
        self:_scheduleGeneration()
        return
    end

    gen.errors = gen.errors + 1
    logger.warn("ttsreader generation failed on page", page, err)
    gen.active = false
    self.generation = nil
    if not self.playback then
        PluginShare.pause_auto_suspend = false
    end
    self:_hideGenerationBar()
    self:_show(T(_("TTS failed on page %1:\n%2"), page, tostring(err)), 8)
end

function TTSReader:_continuePageGeneration(ctx)
    local gen = self.generation
    if not gen or not gen.active or gen.current_page ~= ctx.page then
        return
    end

    while ctx.index <= #ctx.chunks do
        local path = Engine.segmentPath(ctx.book_dir, ctx.page, ctx.index, self.config)
        local meta = Engine.readSegmentMeta(ctx.book_dir, ctx.page, ctx.index)
        if not fileExists(path) or not meta then
            break
        end
        ctx.index = ctx.index + 1
    end

    if ctx.index > #ctx.chunks then
        local ok, err = pcall(Engine.markPageDone, ctx.book_dir, ctx.page, #ctx.chunks)
        self:_finishGenerationPage(ctx.page, ok, err, true)
        return
    end

    local chunk = ctx.chunks[ctx.index]
    local use_timepoints = self.config.line_timepoints ~= false and not ctx.retry_plain
    local input
    if use_timepoints then
        input = {
            ssml = Engine.lineChunkSSML(ctx.lines, chunk),
            enable_timepoints = true,
        }
    else
        input = Engine.lineChunkText(ctx.lines, chunk)
    end

    local job, err = self:_startSynthesizeJob(input)
    if not job then
        self:_finishGenerationPage(ctx.page, false, err, false)
        return
    end
    gen.synth_job = job
    self:_showGenerationBar(false, false)
    self:_pollSynthesizeJob(job, function(audio_path, synth_err, timepoints)
        local active_gen = self.generation
        if not active_gen or not active_gen.active or active_gen.current_page ~= ctx.page then
            removeFile(audio_path)
            return
        end
        active_gen.synth_job = nil
        if not audio_path and use_timepoints then
            logger.warn("ttsreader timepoint synthesis failed on page", ctx.page, "segment", ctx.index, synth_err, "retrying without timepoints")
            ctx.retry_plain = true
            UIManager:scheduleIn(0.05, function()
                self:_continuePageGeneration(ctx)
            end)
            return
        end
        if not audio_path then
            self:_finishGenerationPage(ctx.page, false, synth_err, false)
            return
        end

        local path = Engine.segmentPath(ctx.book_dir, ctx.page, ctx.index, self.config)
        local tmp = path .. ".tmp"
        local ok_move, move_err = moveFile(audio_path, tmp)
        if not ok_move then
            removeFile(tmp)
            removeFile(audio_path)
            self:_finishGenerationPage(ctx.page, false, move_err, false)
            return
        end
        local ok_rename, rename_err = os.rename(tmp, path)
        if not ok_rename then
            removeFile(tmp)
            self:_finishGenerationPage(ctx.page, false, rename_err, false)
            return
        end
        local ok_meta, meta_err = pcall(Engine.writeSegmentMeta, ctx.book_dir, ctx.page, ctx.index, {
            first_line = chunk.first_line,
            last_line = chunk.last_line,
            total_lines = chunk.total_lines,
            timepoints = timepoints or {},
        })
        if not ok_meta then
            self:_finishGenerationPage(ctx.page, false, meta_err, false)
            return
        end

        ctx.index = ctx.index + 1
        ctx.retry_plain = false
        collectgarbage("step", 80)
        UIManager:scheduleIn(0.03, function()
            self:_continuePageGeneration(ctx)
        end)
    end)
end

function TTSReader:startGeneration(options)
    options = options or {}
    if not self:_hasDocument() then
        self:_show(_("Open a book first."))
        return
    end
    if not self:_narrationVoice() then
        self:chooseNarrationLanguage(function()
            self:startGeneration(options)
        end)
        return
    end
    self:_refreshConfig()
    if not self.config.api_key or self.config.api_key == "" then
        self:startKeyServer()
        self:_show(_("Google API key is not set. The setup server has been started."))
        return
    end
    if self.generation and self.generation.active then
        self:_show(_("TTS generation is already running."))
        return
    end

    NetworkMgr:runWhenOnline(function()
        local page_count = math.max(1, tonumber(self:_pageCount()) or 1)
        local chunk_size = tonumber(self.config.page_chunk_size) or 200
        local start_page = math.floor(tonumber(options.start_page) or self:_currentPage() or 1)
        start_page = clamp(start_page, 1, page_count)
        local end_page = math.floor(tonumber(options.end_page) or (start_page + chunk_size - 1))
        end_page = clamp(end_page, start_page, page_count)
        local mode = options.mode == "redownload" and "redownload" or "missing"
        local book_dir = self:_bookDir()
        local cleared = 0
        if mode == "redownload" then
            cleared = Engine.clearPageRangeCache(book_dir, start_page, end_page)
        end
        self.generation = {
            active = true,
            book_dir = book_dir,
            next_page = start_page,
            current_page = nil,
            start_page = start_page,
            end_page = end_page,
            done = 0,
            skipped = 0,
            generated = 0,
            errors = 0,
            mode = mode,
            label = options.label,
            cleared = cleared,
        }
        PluginShare.pause_auto_suspend = true
        self:_showGenerationBar(true, true)
        self:_scheduleGeneration()
    end)
end

function TTSReader:_scheduleGeneration()
    if not self.generation or not self.generation.active then
        return
    end
    self.generation_task = function()
        self:_generateNext()
    end
    UIManager:scheduleIn(self.generation_step_delay, self.generation_task)
end

function TTSReader:_generateNext()
    local gen = self.generation
    if not gen or not gen.active then
        return
    end
    if gen.next_page > gen.end_page then
        gen.active = false
        self.generation = nil
        if not self.playback then
            PluginShare.pause_auto_suspend = false
        end
        self:_hideGenerationBar()
        self:_show(T(_("Ses hazirlandi: %1 sayfa hazir, %2 tekrar kullanildi."), tostring(gen.done), tostring(gen.skipped or 0)), 6)
        return
    end

    local page = gen.next_page
    gen.current_page = page
    self:_showGenerationBar(false, true)
    local status = Engine.pageCacheStatus(gen.book_dir, page, self.config)
    if gen.mode ~= "redownload" and (status.state == "complete" or status.state == "skipped") then
        gen.skipped = (tonumber(gen.skipped) or 0) + 1
        self:_finishGenerationPage(page, true, nil, false)
        return
    end

    local ctx, err, skipped = self:_preparePageGeneration(gen.book_dir, page)
    if skipped then
        gen.skipped = (tonumber(gen.skipped) or 0) + 1
        self:_finishGenerationPage(page, true, nil, false)
        return
    end
    if not ctx then
        self:_finishGenerationPage(page, false, err, false)
        return
    end
    self:_continuePageGeneration(ctx)
end

function TTSReader:stopGeneration(show_message)
    if self.generation_task then
        UIManager:unschedule(self.generation_task)
        self.generation_task = nil
    end
    if self.generation then
        if self.generation.synth_job then
            self:_cancelAsyncJob(self.generation.synth_job)
            self.generation.synth_job = nil
        end
        self.generation.active = false
        self.generation = nil
        self:_hideGenerationBar()
        if not self.playback then
            PluginShare.pause_auto_suspend = false
        end
        if show_message ~= false then
            self:_show(_("TTS generation stopped."))
        end
    end
end

local function progressBar(percentage)
    percentage = clamp(tonumber(percentage) or 0, 0, 1)
    local width = 18
    local filled = math.floor(percentage * width + 0.5)
    return "[" .. string.rep("=", filled) .. string.rep("-", width - filled) .. "]"
end

function TTSReader:_bottomBarWidth()
    return math.floor(Screen:getWidth() * 0.92)
end

function TTSReader:_bottomBarX(width)
    return math.floor((Screen:getWidth() - width) / 2)
end

function TTSReader:_generationAnchor()
    local width = self:_bottomBarWidth()
    return Geom:new{
        x = self:_bottomBarX(width),
        y = Screen:getHeight(),
        w = width,
        h = 0,
    }
end

function TTSReader:_generationBarHeight()
    if self.generation_bar then
        return self.generation_bar:_barHeight()
    end
    return TTSReaderGenerationBar.bar_height
end

function TTSReader:_playbackBarHeight()
    if self.playback_bar then
        return self.playback_bar:_barHeight()
    end
    return math.max(TTSReaderPlayerBar.bar_height, math.floor(Screen:getHeight() * 0.115))
end

function TTSReader:_readerBottomReserve()
    local reserve = 0
    if self.playback and self.playback.active then
        reserve = reserve + self:_playbackBarHeight()
    end
    if self.generation and self.generation.active and not (self.ui and self.ui.rolling) then
        reserve = reserve + self:_generationBarHeight()
    end
    return math.min(reserve, math.max(0, Screen:getHeight() - 1))
end

function TTSReader:_applyReaderBottomReserve()
    if not self.ui or not self.ui.view then
        return
    end
    local reserve = self:_readerBottomReserve()
    local applied_reserve = tonumber(self.ui.ttsreader_bottom_reserve) or 0
    if applied_reserve == reserve and (self.reader_bottom_reserve == nil or self.reader_bottom_reserve == reserve) then
        self.reader_bottom_reserve = reserve
        return
    end
    self.reader_bottom_reserve = reserve
    self.ui.ttsreader_bottom_reserve = reserve > 0 and reserve or nil
    logger.info("ttsreader bottom reserve:", reserve)
    self.ui:handleEvent(Event:new("SetDimensions", Screen:getSize()))
    if self.ui.paging then
        self.ui:handleEvent(Event:new("RedrawCurrentPage"))
    elseif self.ui.rolling then
        self.ui:handleEvent(Event:new("RedrawCurrentView"))
    end
    UIManager:setDirty(self.ui, "full")
end

function TTSReader:_generationStatusText()
    local gen = self.generation
    if not gen or not gen.active then
        return _("TTS onbellegi")
    end

    local total = math.max(1, (tonumber(gen.end_page) or 0) - (tonumber(gen.start_page) or 0) + 1)
    local done = math.max(0, tonumber(gen.done) or 0)
    local page = tonumber(gen.current_page) or tonumber(gen.next_page) or tonumber(gen.start_page) or 0
    local pct = clamp(done / total, 0, 1)
    local state = gen.current_page and _("Hazirlaniyor") or _("Bekliyor")
    local label = gen.label or (gen.mode == "redownload" and _("Bastan indir") or _("Eksikler"))
    local rows = {
        T(_("TTS onbellegi: %1  %2/%3 sayfa"), state, tostring(done), tostring(total)),
        T(_("%1  Sayfa %2-%3  Simdi %4  %5%"), label, tostring(gen.start_page), tostring(gen.end_page), tostring(page), tostring(math.floor(pct * 100 + 0.5))),
        progressBar(pct),
    }
    if (tonumber(gen.skipped) or 0) > 0 then
        rows[#rows + 1] = T(_("Tekrar: %1"), tostring(gen.skipped))
    end
    if (tonumber(gen.errors) or 0) > 0 then
        rows[#rows + 1] = T(_("Errors: %1"), tostring(gen.errors))
    end
    return table.concat(rows, "\n")
end

function TTSReader:_hideGenerationBar()
    local bar = self.generation_bar
    if not bar then
        return
    end
    local old_rect = bar.dimen or bar:_barRect()
    if self.ui and self.ui.view and self.ui.view.view_modules then
        self.ui.view.view_modules.ttsreader_generation_bar = nil
    end
    if self.ui and self.generation_bar_registered then
        for i = #self.ui, 1, -1 do
            if self.ui[i] == bar then
                table.remove(self.ui, i)
                break
            end
        end
    end
    self.generation_bar_registered = nil
    self.generation_bar = nil
    self.generation_bar_title = nil
    self.generation_bar_render_key = nil
    self:_applyReaderBottomReserve()
    if self.ui and old_rect then
        UIManager:setDirty(self.ui, "ui", old_rect)
    end
    if self.playback and self.playback.active then
        self:_reopenPlaybackControls()
    end
end

function TTSReader:_installGenerationBar()
    if not self.ui or not self.ui.view then
        return nil
    end
    if not self.generation_bar then
        self.generation_bar = TTSReaderGenerationBar:new{
            owner = self,
            ui = self.ui,
            view = self.ui.view,
        }
    end
    if self.ui.view.view_modules.ttsreader_generation_bar ~= self.generation_bar then
        self.ui.view:registerViewModule("ttsreader_generation_bar", self.generation_bar)
    end
    if not self.generation_bar_registered then
        table.insert(self.ui, 2, self.generation_bar)
        self.generation_bar_registered = true
    end
    self:_applyReaderBottomReserve()
    return self.generation_bar
end

function TTSReader:_generationRenderKey()
    local gen = self.generation
    if not gen or not gen.active then
        return ""
    end
    local total = math.max(1, (tonumber(gen.end_page) or 0) - (tonumber(gen.start_page) or 0) + 1)
    local done = math.max(0, tonumber(gen.done) or 0)
    local page = tonumber(gen.current_page) or tonumber(gen.next_page) or tonumber(gen.start_page) or 0
    return table.concat({
        tostring(gen.current_page and "working" or "waiting"),
        tostring(done),
        tostring(total),
        tostring(page),
        tostring(gen.start_page or 0),
        tostring(gen.end_page or 0),
        tostring(gen.skipped or 0),
        tostring(gen.errors or 0),
        tostring(gen.mode or ""),
        tostring(gen.label or ""),
    }, "|")
end

function TTSReader:_refreshGenerationBar(rebuild)
    local bar = self:_installGenerationBar()
    if not bar then
        return
    end
    local old_rect = bar.dimen
    local new_rect = bar:_barRect()
    local layout_changed = not old_rect
        or old_rect.x ~= new_rect.x
        or old_rect.y ~= new_rect.y
        or old_rect.w ~= new_rect.w
        or old_rect.h ~= new_rect.h
    local render_key = self:_generationRenderKey()
    if not rebuild and not layout_changed and self.generation_bar_render_key == render_key then
        return
    end
    self.generation_bar_render_key = render_key
    if old_rect and layout_changed then
        UIManager:setDirty(self.ui, "ui", old_rect)
    end
    UIManager:setDirty(self.ui, "ui", new_rect)
    if rebuild and self.playback and self.playback.active then
        self:_showPlaybackControls(true)
    end
end

function TTSReader:_showGenerationBar(rebuild)
    if not self.generation or not self.generation.active then
        self:_hideGenerationBar()
        return
    end
    if rebuild then
        self:_hideGenerationBar()
    end
    self:_refreshGenerationBar(rebuild)
end

function TTSReader:_nativePlayerLib()
    if self.native_player_lib ~= nil then
        return self.native_player_lib or nil
    end
    self.native_player_lib = false
    if not ffi_ok then
        return nil
    end
    if not ttsreader_player_cdef_loaded then
        ffi.cdef[[
            int ttsreader_player_signal(int pid, int signo);
            int ttsreader_player_alive(int pid);
            int ttsreader_player_reap(int pid);
            int ttsreader_player_poll(int pid);
            int ttsreader_player_spawn(const char *player_path, const char *audio_path, const char *device, double speed, double seek_seconds, double volume);
            int ttsreader_player_spawn_control(const char *player_path, const char *audio_path, const char *device, double speed, double seek_seconds, double volume, const char *volume_control_path);
            double ttsreader_player_elapsed(double offset, double wall_delta, double speed);
        ]]
        ttsreader_player_cdef_loaded = true
    end
    local ok, lib = pcall(function()
        if ffi.loadlib then
            return ffi.loadlib("ttsreader-player")
        end
        return ffi.load("libs/libttsreader-player.so")
    end)
    if ok and lib then
        self.native_player_lib = lib
        return lib
    end
end

function TTSReader:_signalPid(pid, signo)
    pid = tonumber(pid)
    if not pid then
        return false
    end
    local native = self:_nativePlayerLib()
    if native then
        return native.ttsreader_player_signal(pid, signo) == 0
    end
    return os.execute("kill -" .. tostring(signo) .. " " .. pid .. " >/dev/null 2>&1") == true
end

function TTSReader:_playbackElapsed()
    local playback = self.playback
    if not playback then
        return 0
    end
    local offset = tonumber(playback.segment_audio_offset) or 0
    if not playback.segment_started_at or playback.paused then
        return offset
    end
    local wall_delta = socket.gettime() - playback.segment_started_at
    local speed = tonumber(playback.effective_speed) or 1
    local native = self:_nativePlayerLib()
    if native then
        return tonumber(native.ttsreader_player_elapsed(offset, wall_delta, speed)) or offset
    end
    return offset + math.max(0, wall_delta) * speed
end

function TTSReader:_playbackSpeed()
    local playback = self.playback
    if playback and playback.speed then
        return Engine.normalizePlaybackSpeed(playback.speed)
    end
    return Engine.normalizePlaybackSpeed(self.config.playback_speed)
end

function TTSReader:_playbackVolume()
    local playback = self.playback
    if playback and playback.volume then
        return Engine.normalizePlaybackVolume(playback.volume)
    end
    return Engine.normalizePlaybackVolume(self.config.playback_volume)
end

function TTSReader:_bluetoothctlPath()
    if self.bluetoothctl_path ~= nil then
        return self.bluetoothctl_path or nil
    end
    local path = firstLine("command -v bluetoothctl 2>/dev/null")
    self.bluetoothctl_path = path and path ~= "" and path or false
    return self.bluetoothctl_path or nil
end

function TTSReader:_requireBluetoothctl()
    if self:_bluetoothctlPath() then
        return true
    end
    self:_show(_("bluetoothctl was not found on this Kobo. Bluetooth headphones cannot be managed from KOReader."), 8)
    return false
end

function TTSReader:_bluetoothScriptCommand(script, timeout_seconds)
    local timeout = math.floor(clamp(tonumber(timeout_seconds) or 14, 1, 60))
    local quoted_script = shellQuote(script)
    local wrapped = string.format([[
tmp="${TMPDIR:-/tmp}/ttsreader-bt-$$.out"
rm -f "$tmp"
if command -v setsid >/dev/null 2>&1; then
    setsid sh -c %s >"$tmp" 2>&1 &
    pid=$!
    kill_target="-$pid"
else
    sh -c %s >"$tmp" 2>&1 &
    pid=$!
    kill_target="$pid"
fi
i=0
while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge %d ]; then
        kill -TERM $kill_target 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL $kill_target 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        cat "$tmp" 2>/dev/null
        echo %s
        rm -f "$tmp"
        exit 124
    fi
    sleep 1
    i=$((i + 1))
done
wait "$pid"
rc=$?
cat "$tmp" 2>/dev/null
rm -f "$tmp"
exit "$rc"
]], quoted_script, quoted_script, timeout, BT_TIMEOUT_MARKER)
    return "sh -c " .. shellQuote(wrapped)
end

function TTSReader:_runBluetoothScript(script, timeout_seconds)
    return commandOutput(self:_bluetoothScriptCommand(script, timeout_seconds))
end

function TTSReader:_newAsyncJob(prefix, timeout_seconds)
    self.async_job_seq = (self.async_job_seq or 0) + 1
    local base = string.format(
        "/tmp/ttsreader-%s-%d-%d",
        tostring(prefix or "job"):gsub("[^%w_-]", ""),
        os.time(),
        self.async_job_seq
    )
    return {
        output = base .. ".out",
        tmp_output = base .. ".tmp",
        done = base .. ".done",
        pid = base .. ".pid",
        started_at = socket.gettime(),
        timeout = tonumber(timeout_seconds) or 30,
    }
end

function TTSReader:_launchAsyncJob(job, command)
    local runner = table.concat({
        "rm -f " .. shellQuote(job.output) .. " " .. shellQuote(job.tmp_output) .. " " .. shellQuote(job.done) .. " " .. shellQuote(job.pid),
        "(" .. command .. ") >" .. shellQuote(job.tmp_output) .. " 2>&1 &",
        "child_pid=$!",
        "printf '%s\\n' \"$child_pid\" > " .. shellQuote(job.pid),
        "wait \"$child_pid\"",
        "rc=$?",
        "if [ -f " .. shellQuote(job.tmp_output) .. " ]; then mv -f " .. shellQuote(job.tmp_output) .. " " .. shellQuote(job.output) .. "; else : >" .. shellQuote(job.output) .. "; fi",
        "printf '%s\\n' \"$rc\" >" .. shellQuote(job.done),
    }, "\n")
    local launcher = "sh -c " .. shellQuote(runner .. "\n") .. " &"
    os.execute("sh -c " .. shellQuote(launcher .. "\n"))
    return job
end

function TTSReader:_startAsyncCommand(command, prefix, timeout_seconds)
    return self:_launchAsyncJob(self:_newAsyncJob(prefix, timeout_seconds), command)
end

function TTSReader:_detachAsyncJobExtraFile(job, path)
    if not job or not path or path == "" then
        return
    end
    local files = job.extra_files
    if type(files) ~= "table" then
        return
    end
    for i = #files, 1, -1 do
        if files[i] == path then
            table.remove(files, i)
        end
    end
end

function TTSReader:_cleanupAsyncJob(job)
    if not job then
        return
    end
    removeFile(job.output)
    removeFile(job.tmp_output)
    removeFile(job.done)
    removeFile(job.pid)
    for _idx, path in ipairs(job.extra_files or {}) do
        removeFile(path)
    end
end

function TTSReader:_cancelAsyncJob(job)
    if not job then
        return
    end
    job.cancelled = true
    local pid = job.pid and tonumber((readFile(job.pid):match("(%d+)")))
    if pid and pid > 1 then
        os.execute("kill -TERM " .. tostring(pid) .. " >/dev/null 2>&1; usleep 300000; kill -0 " .. tostring(pid) .. " >/dev/null 2>&1 && kill -KILL " .. tostring(pid) .. " >/dev/null 2>&1; usleep 100000")
    end
    self:_cleanupAsyncJob(job)
end

function TTSReader:_pollAsyncJob(job, done_callback, timeout_callback, interval)
    if not job or job.cancelled then
        return
    end
    if fileExists(job.done) then
        local output = readFile(job.output)
        local status = tonumber((readFile(job.done):match("(%-?%d+)")))
        done_callback(output, status)
        self:_cleanupAsyncJob(job)
        return
    end
    if socket.gettime() - job.started_at > (job.timeout + 3) then
        self:_cancelAsyncJob(job)
        if timeout_callback then
            timeout_callback()
        end
        return
    end
    UIManager:scheduleIn(tonumber(interval) or 0.35, function()
        self:_pollAsyncJob(job, done_callback, timeout_callback, interval)
    end)
end

function TTSReader:_bluetoothScriptPrefix()
    return [[
is_running() {
    name="$1"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep "$name" >/dev/null 2>&1
        return $?
    fi
    ps | grep "$name" | grep -v grep >/dev/null 2>&1
}
bluez_ready() {
    dbus-send --system --print-reply --dest=org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties.Get string:org.bluez.Adapter1 string:Powered >/dev/null 2>&1
}
start_bluetoothd() {
    if [ -x /libexec/bluetooth/bluetoothd ]; then
        /libexec/bluetooth/bluetoothd >/tmp/ttsreader-bluetoothd.log 2>&1 &
    fi
}
ensure_bt_controller() {
    if ! is_running "dbus-daemon" && command -v dbus-daemon >/dev/null 2>&1; then
        dbus-daemon --system --fork >/tmp/ttsreader-dbus.log 2>&1 || true
        sleep 0.2
    fi
    if [ -e /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko ] && ! grep -q '^sdio_bt_pwr ' /proc/modules 2>/dev/null; then
        insmod /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko >/tmp/ttsreader-bt-power.log 2>&1 || true
        sleep 0.2
    fi
    if ! hciconfig hci0 >/dev/null 2>&1; then
        if [ -x /sbin/rtk_hciattach ] && ! is_running "rtk_hciattach"; then
            /sbin/rtk_hciattach -t 8 -s 115200 ttymxc1 rtk_h5 >/tmp/ttsreader-rtk-hciattach.log 2>&1 || true
        fi
        i=0
        while [ "$i" -lt 25 ] && ! hciconfig hci0 >/dev/null 2>&1; do
            sleep 0.2
            i=$((i + 1))
        done
    fi
    if ! hciconfig hci0 >/dev/null 2>&1; then
        echo ]] .. BT_STACK_FAILED_MARKER .. [[
        cat /tmp/ttsreader-rtk-hciattach.log 2>/dev/null || true
        return 1
    fi
    hciconfig hci0 up >/dev/null 2>&1 || true
    if ! is_running "bluetoothd"; then
        start_bluetoothd
        sleep 0.5
    fi
    i=0
    while [ "$i" -lt 20 ] && ! bluez_ready; do
        sleep 0.1
        i=$((i + 1))
    done
    if ! bluez_ready; then
        killall bluetoothd >/dev/null 2>&1 || true
        sleep 0.2
        start_bluetoothd
        sleep 0.6
    fi
    if ! bluez_ready; then
        echo ]] .. BT_STACK_FAILED_MARKER .. [[
        cat /tmp/ttsreader-bluetoothd.log 2>/dev/null || true
        return 1
    fi
    dbus-send --system --print-reply --dest=org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties.Set string:org.bluez.Adapter1 string:Powered variant:boolean:true >/dev/null 2>&1 || true
    return 0
}
ensure_bluealsa() {
    ensure_bt_controller || return 1
    if [ -x /bin/bluealsa ] && ! is_running "bluealsa"; then
        /bin/bluealsa -S -i hci0 --a2dp-force-mono >/tmp/ttsreader-bluealsa.log 2>&1 &
    fi
    i=0
    while [ "$i" -lt 10 ] && [ -x /bin/bluealsa ] && ! is_running "bluealsa"; do
        sleep 0.1
        i=$((i + 1))
    done
    if [ -x /bin/bluealsa ] && ! is_running "bluealsa"; then
        echo ]] .. BT_STACK_FAILED_MARKER .. [[
        cat /tmp/ttsreader-bluealsa.log 2>/dev/null || true
        return 1
    fi
    return 0
}
bt() {
    limit="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$limit" bluetoothctl "$@"
        return $?
    fi
    bluetoothctl "$@" &
    bt_pid=$!
    bt_i=0
    while kill -0 "$bt_pid" 2>/dev/null; do
        if [ "$bt_i" -ge "$limit" ]; then
            kill "$bt_pid" 2>/dev/null || true
            sleep 1
            kill -9 "$bt_pid" 2>/dev/null || true
            wait "$bt_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        bt_i=$((bt_i + 1))
    done
    wait "$bt_pid"
}
bt_scan_off_quiet() {
    bt_show="$(bt 4 show 2>/dev/null || true)"
    if printf '%s\n' "$bt_show" | grep -q 'Discovering: yes'; then
        bt 4 scan off "$@" >/dev/null 2>&1 || true
    fi
    return 0
}
]]
end

function TTSReader:_parseBluetoothDeviceInfo(mac, output)
    local info = {
        mac = mac,
        name = mac,
        connected = false,
        paired = false,
        trusted = false,
    }
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
        if key == "Name" or key == "Alias" then
            if value ~= "" then
                info.name = value
            end
        elseif key == "Connected" then
            info.connected = value == "yes"
        elseif key == "Paired" then
            info.paired = value == "yes"
        elseif key == "Trusted" then
            info.trusted = value == "yes"
        end
    end
    return info
end

function TTSReader:_bluetoothDeviceInfo(mac)
    mac = Engine.bluetoothMac(mac)
    if mac == "" or not self:_bluetoothctlPath() then
        return {
            mac = mac,
            name = mac,
            connected = false,
            paired = false,
            trusted = false,
        }
    end

    local output = self:_runBluetoothScript(self:_bluetoothScriptPrefix() .. "\nensure_bt_controller >/dev/null 2>&1 || true\nbt 4 info " .. shellQuote(mac) .. " || true", 8)
    return self:_parseBluetoothDeviceInfo(mac, output)
end

function TTSReader:_resetBluetoothRuntimeState()
    self:_invalidateBluetoothReady()
    self.bluetooth_last_audio_at = nil
    self.headset_input_refresh_token = (self.headset_input_refresh_token or 0) + 1
    self.headset_input_refresh_started_at = nil
    for path in pairs(self.headset_input_paths or {}) do
        self:_closeHeadsetInputPath(path)
    end
    self.headset_input_paths = {}
    self:_refreshHeadsetInputReady()
end

function TTSReader:_cancelBluetoothIdleShutdown()
    self.bluetooth_idle_shutdown_token = (self.bluetooth_idle_shutdown_token or 0) + 1
    if self.bluetooth_idle_shutdown_task then
        UIManager:unschedule(self.bluetooth_idle_shutdown_task)
        self.bluetooth_idle_shutdown_task = nil
    end
    if self.bluetooth_poweroff_job then
        self:_cancelAsyncJob(self.bluetooth_poweroff_job)
        self.bluetooth_poweroff_job = nil
    end
end

function TTSReader:_scheduleBluetoothIdleShutdown(delay)
    self:_cancelBluetoothIdleShutdown()
    local token = self.bluetooth_idle_shutdown_token
    self.bluetooth_idle_shutdown_task = function()
        self.bluetooth_idle_shutdown_task = nil
        if token ~= self.bluetooth_idle_shutdown_token then
            return
        end
        if (self.playback and self.playback.pid)
            or self.bluetooth_connect_job
            or self.bluetooth_scan_job
            or self.bluetooth_pair_job
        then
            self:_scheduleBluetoothIdleShutdown(30)
            return
        end
        local script = Engine.bluetoothPowerOffScript()
        local job = self:_startAsyncCommand("sh -c " .. shellQuote(script), "bt-off", 4)
        self.bluetooth_poweroff_job = job
        self:_pollAsyncJob(job, function()
            self.bluetooth_poweroff_job = nil
            self:_resetBluetoothRuntimeState()
        end, function()
            self.bluetooth_poweroff_job = nil
            self:_scheduleBluetoothIdleShutdown(30)
        end, 0.5)
    end
    UIManager:scheduleIn(tonumber(delay) or self.bluetooth_idle_poweroff_seconds, self.bluetooth_idle_shutdown_task)
end

function TTSReader:_audioDevice()
    return Engine.bluetoothAudioDevice(self.config.bluetooth_mac)
end

function TTSReader:_hasBluetoothAudio()
    return Engine.hasBluetoothAudio(self.config)
end

function TTSReader:_bluetoothMac()
    return Engine.bluetoothMac(self.config.bluetooth_mac)
end

function TTSReader:_markBluetoothReady(seconds)
    local mac = self:_bluetoothMac()
    if mac == "" then
        return
    end
    self.bluetooth_ready_mac = mac
    self.bluetooth_ready_until = socket.gettime() + (tonumber(seconds) or 12)
    self:_scheduleHeadsetInputRefreshBurst()
end

function TTSReader:_bluetoothRecentlyReady()
    local mac = self:_bluetoothMac()
    return mac ~= ""
        and self.bluetooth_ready_mac == mac
        and self.bluetooth_ready_until
        and socket.gettime() < self.bluetooth_ready_until
end

function TTSReader:_markBluetoothAudioActive()
    if self:_bluetoothMac() ~= "" then
        self:_cancelBluetoothIdleShutdown()
        self.bluetooth_last_audio_at = socket.gettime()
    end
end

function TTSReader:_bluetoothRecentlyActive(seconds)
    local last = tonumber(self.bluetooth_last_audio_at)
    return last ~= nil and socket.gettime() - last < (tonumber(seconds) or 45)
end

function TTSReader:_bluetoothNeedsRefresh()
    if not self:_hasBluetoothAudio() then
        return false
    end
    local idle = tonumber(self.config.bluetooth_idle_refresh_seconds) or Engine.defaults.bluetooth_idle_refresh_seconds
    return not self:_bluetoothRecentlyReady() and not self:_bluetoothRecentlyActive(idle)
end

function TTSReader:_bluetoothIdleStatus()
    if not self:_hasBluetoothAudio() then
        return nil
    end
    return self:_bluetoothRecentlyReady() and _("ready") or _("not connected")
end

function TTSReader:_invalidateBluetoothReady()
    self.bluetooth_ready_mac = nil
    self.bluetooth_ready_until = nil
end

function TTSReader:_bluetoothConnectCommand(force_refresh)
    if self.config.bluetooth_connect_cmd and self.config.bluetooth_connect_cmd ~= "" then
        return self.config.bluetooth_connect_cmd
    end
    local mac = self:_bluetoothMac()
    if mac ~= "" then
        local script = self:_bluetoothScriptPrefix() .. Engine.bluetoothConnectScript(mac, force_refresh)
        return self:_bluetoothScriptCommand(script, 24)
    end
end

function TTSReader:_bundledPlayer()
    if self.bundled_player ~= nil then
        return self.bundled_player or nil
    end
    local paths = {
        "./bin/ttsreader-play",
        "/mnt/onboard/.adds/koreader/bin/ttsreader-play",
        "/mnt/sd/.adds/koreader/bin/ttsreader-play",
    }
    for i = 1, #paths do
        if fileExists(paths[i]) then
            self.bundled_player = paths[i]
            return self.bundled_player
        end
    end
    self.bundled_player = false
end

function TTSReader:_rememberPlaybackLocation()
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    if playback.finished then
        self.resume_playback = nil
        return
    end
    self.resume_playback = {
        book_dir = playback.book_dir,
        page = playback.page,
        segment_index = playback.segment_index or 1,
        elapsed = self:_playbackElapsed(),
        line = self:_currentPlaybackLine(),
    }
end

function TTSReader:_setPlaybackLineAtElapsed(meta, elapsed, use_current_index)
    local playback = self.playback
    if not playback or not meta then
        return nil
    end
    local line, _, index = Engine.lineAndNextDelayFrom(
        meta,
        elapsed or 0,
        playback.effective_speed or playback.speed,
        0.65,
        2.0,
        use_current_index and playback.line_timepoint_index or nil,
        use_current_index and playback.current_line or nil
    )
    line = line or meta.first_line
    playback.current_line = line
    playback.line_timepoint_index = index
    return line
end

function TTSReader:_currentPlaybackLine(elapsed)
    local playback = self.playback
    if not playback or not playback.active then
        return nil
    end
    local entry = playback.current_entry
    local meta = entry and entry.meta
    if not meta then
        return nil
    end
    if playback.segment_started_at then
        if elapsed == nil and playback.current_line then
            return playback.current_line
        end
        return self:_setPlaybackLineAtElapsed(meta, elapsed or self:_playbackElapsed(), true)
    end
    return playback.current_line or meta.first_line
end

function TTSReader:_playbackStatusText()
    local playback = self.playback
    if not playback or not playback.active then
        return _("Audio mode")
    end

    local entry = playback.current_entry or {}
    local meta = entry.meta or {}
    local total_lines = tonumber(meta.total_lines) or #(playback.page_lines or {})
    local current_line = playback.current_line or self:_currentPlaybackLine() or tonumber(meta.first_line) or 0
    local segment_count = playback.segment_entries and #playback.segment_entries or 1
    local segment_index = playback.segment_index or 1
    local requested_speed = Engine.speedLabel(playback.speed or 1)
    local effective_speed = Engine.speedLabel(playback.effective_speed or playback.speed or 1)
    local pct
    local detail

    if total_lines > 0 and current_line > 0 then
        pct = current_line / total_lines
        detail = T(_("Page %1/%2  Line %3/%4"), tostring(playback.page), tostring(playback.page_count), tostring(current_line), tostring(total_lines))
    else
        pct = segment_index / math.max(segment_count, 1)
        detail = T(_("Page %1/%2  Segment %3/%4"), tostring(playback.page), tostring(playback.page_count), tostring(segment_index), tostring(segment_count))
    end

    local state
    if playback.ready_to_play or not playback.pid then
        state = _("Ready")
    elseif playback.paused then
        state = _("Paused")
    else
        state = _("Playing")
    end
    local speed_detail = requested_speed == effective_speed
        and T(_("Speed %1"), requested_speed)
        or T(_("Speed %1 requested, %2 active"), requested_speed, effective_speed)
    local volume_detail = playback.volume_supported == false
        and T(_("Volume %1 requested, player default active"), Engine.volumeLabel(playback.volume or self:_playbackVolume()))
        or T(_("Volume %1"), Engine.volumeLabel(playback.volume or self:_playbackVolume()))
    local line = playback.page_lines and playback.page_lines[current_line] or ""
    local rows = {
        T(_("Audio mode: %1"), state),
        detail,
        speed_detail,
        volume_detail,
    }
    if playback.bluetooth_status then
        rows[#rows + 1] = T(_("Kulaklik: %1"), Engine.bluetoothStatusLabel(playback.bluetooth_status))
    end
    rows[#rows + 1] =
        T("%1 %2%", progressBar(pct), tostring(math.floor(clamp(pct, 0, 1) * 100 + 0.5)))
    rows[#rows + 1] = shortLine(line)
    return table.concat(rows, "\n")
end

function TTSReader:_installPlaybackBar()
    if not self.ui or not self.ui.view then
        return nil
    end
    local has_existing_bar = self.playback_bar ~= nil
    if self:_headsetInputBarRefreshNeeded(has_existing_bar) then
        self:_ensureHeadsetInputOpen()
    end
    if not self.playback_bar then
        self.playback_bar = TTSReaderPlayerBar:new{
            owner = self,
            ui = self.ui,
            view = self.ui.view,
        }
    end
    if self.ui.view.view_modules.ttsreader_player_bar ~= self.playback_bar then
        self.ui.view:registerViewModule("ttsreader_player_bar", self.playback_bar)
    end
    if not self.playback_bar_registered then
        table.insert(self.ui, 2, self.playback_bar)
        self.playback_bar_registered = true
    end
    self:_applyReaderBottomReserve()
    return self.playback_bar
end

function TTSReader:_removePlaybackBar()
    local bar = self.playback_bar
    if not bar then
        return
    end
    local old_rect = bar.dimen or bar:_barRect()
    if self.ui and self.ui.view and self.ui.view.view_modules then
        self.ui.view.view_modules.ttsreader_player_bar = nil
    end
    if self.ui and self.playback_bar_registered then
        for i = #self.ui, 1, -1 do
            if self.ui[i] == bar then
                table.remove(self.ui, i)
                break
            end
        end
    end
    self.playback_bar_registered = nil
    if bar.freeCache then
        bar:freeCache()
    end
    self.playback_bar = nil
    self.playback_bar_render_key = nil
    self:_applyReaderBottomReserve()
    if self.ui and old_rect then
        UIManager:setDirty(self.ui, "ui", old_rect)
    end
end

function TTSReader:_playbackRenderKey()
    local playback = self.playback
    if not playback or not playback.active then
        return ""
    end
    local entry = playback.current_entry or {}
    local meta = entry.meta or {}
    local line = playback.current_line or self:_currentPlaybackLine() or tonumber(meta.first_line) or 0
    local total_lines = tonumber(meta.total_lines) or #(playback.page_lines or {})
    local segment_count = playback.segment_entries and #playback.segment_entries or 1
    local state = playback.ready_to_play and "ready"
        or (playback.paused and "paused")
        or (playback.pid and "playing" or "ready")
    return table.concat({
        state,
        tostring(playback.page or 0),
        tostring(playback.page_count or 0),
        tostring(line),
        tostring(total_lines),
        tostring(playback.segment_index or 1),
        tostring(segment_count),
        Engine.speedLabel(playback.speed or 1),
        Engine.speedLabel(playback.effective_speed or playback.speed or 1),
        Engine.volumeLabel(playback.volume or self:_playbackVolume()),
        tostring(playback.bluetooth_status or ""),
    }, "|")
end

function TTSReader:_refreshPlaybackBar(rebuild)
    local bar = self:_installPlaybackBar()
    if not bar then
        return
    end
    local old_rect = bar.dimen
    local new_rect = bar:_barRect()
    local layout_changed = not old_rect
        or old_rect.x ~= new_rect.x
        or old_rect.y ~= new_rect.y
        or old_rect.w ~= new_rect.w
        or old_rect.h ~= new_rect.h
    local render_key = self:_playbackRenderKey()
    if not rebuild and not layout_changed and self.playback_bar_render_key == render_key then
        return
    end
    self.playback_bar_render_key = render_key
    if old_rect and layout_changed then
        UIManager:setDirty(self.ui, "ui", old_rect)
    end
    local snapshot = bar:_snapshot()
    local static_unchanged = snapshot
        and bar.static_bb
        and bar.static_cache_key == bar:_staticCacheKey(snapshot, new_rect, bar.static_bb:getType())
    UIManager:setDirty(
        self.ui,
        "ui",
        not rebuild and not layout_changed and static_unchanged and bar:_dynamicRect(new_rect) or new_rect
    )
end

function TTSReader:_showPlaybackControls(rebuild)
    if not self.playback or not self.playback.active then
        return
    end
    self:_refreshPlaybackBar(rebuild)
end

function TTSReader:_hidePlaybackControls()
    self:_removePlaybackBar()
end

function TTSReader:_reopenPlaybackControls()
    self:_refreshPlaybackBar(true)
end

function TTSReader:_playbackIndicatorDelay(elapsed)
    local playback = self.playback
    if not playback or playback.paused then
        return 1.2
    end
    local entry = playback.current_entry
    local meta = entry and entry.meta
    if meta and meta.timepoints and #meta.timepoints > 0 then
        return Engine.nextLineDelay(meta, elapsed or self:_playbackElapsed(), playback.effective_speed or playback.speed, 0.65, 2.0)
    end
    return 1.2
end

function TTSReader:_schedulePlaybackIndicator()
    if self.playback_indicator_task then
        return
    end
    self.playback_indicator_task = function()
        self:_tickPlaybackIndicator()
    end
    UIManager:scheduleIn(self:_playbackIndicatorDelay(), self.playback_indicator_task)
end

function TTSReader:_unschedulePlaybackIndicator()
    if self.playback_indicator_task then
        UIManager:unschedule(self.playback_indicator_task)
        self.playback_indicator_task = nil
    end
end

function TTSReader:_tickPlaybackIndicator()
    local task = self.playback_indicator_task
    if not self.playback or not self.playback.active then
        self.playback_indicator_task = nil
        return
    end

    local playback = self.playback
    local elapsed = self:_playbackElapsed()
    local entry = playback.current_entry
    local meta = entry and entry.meta
    local delay
    local line
    if meta and meta.timepoints and #meta.timepoints > 0 then
        line, delay, playback.line_timepoint_index = Engine.lineAndNextDelayFrom(
            meta,
            elapsed,
            playback.effective_speed or playback.speed,
            0.65,
            2.0,
            playback.line_timepoint_index,
            playback.current_line
        )
        line = line or meta.first_line
    else
        line = self:_currentPlaybackLine(elapsed)
        delay = self:_playbackIndicatorDelay(elapsed)
    end
    if line and line ~= self.playback.current_line then
        self.playback.current_line = line
        local now = socket.gettime()
        if not playback.next_indicator_paint_at or now >= playback.next_indicator_paint_at then
            playback.next_indicator_paint_at = now + self.playback_ui_min_interval
            self:_showPlaybackControls()
        end
    end
    UIManager:scheduleIn(delay or 1.2, task)
end

function TTSReader:_detectPlayer(speed)
    if self.config.player_cmd and self.config.player_cmd ~= "" then
        return self.config.player_cmd
    end
    local bundled = self:_bundledPlayer()
    if bundled then
        return bundled
    end
    local query
    if Engine.normalizePlaybackSpeed(speed) ~= 1.0 then
        query = "command -v mpv 2>/dev/null || command -v mplayer 2>/dev/null || command -v ffplay 2>/dev/null || command -v mpg123 2>/dev/null || command -v madplay 2>/dev/null"
    else
        query = "command -v mpg123 2>/dev/null || command -v madplay 2>/dev/null || command -v mpv 2>/dev/null || command -v mplayer 2>/dev/null || command -v ffplay 2>/dev/null"
    end
    local candidate = firstLine(query)
    if candidate and candidate ~= "" then
        return candidate
    end
end

function TTSReader:_playerCommand(player, path, speed, seek_seconds, volume, volume_control_path)
    return Engine.playerCommand(player, path, speed, seek_seconds, self:_audioDevice(), volume, volume_control_path)
end

function TTSReader:_pidState(pid)
    if not pid then
        return "exited"
    end
    local native = self:_nativePlayerLib()
    if native and self.playback and self.playback.native_spawned then
        local ok, status = pcall(function()
            return tonumber(native.ttsreader_player_poll(tonumber(pid)))
        end)
        if ok and status then
            if status == 0 then
                return "running"
            elseif status == 1 then
                return "exited"
            end
            return "failed", status
        else
            status = tonumber(native.ttsreader_player_reap(tonumber(pid)))
            if status == 0 then
                return "running"
            elseif status == 1 then
                return "exited"
            end
        end
    end
    if native then
        return native.ttsreader_player_alive(tonumber(pid)) == 1 and "running" or "exited"
    end
    local shell_state, shell_status = self:_shellPlayerStatus(pid)
    if shell_state then
        return shell_state, shell_status
    end
    local status = firstLine("kill -0 " .. tonumber(pid) .. " 2>/dev/null; echo $?")
    return tostring(status) == "0" and "running" or "exited"
end

function TTSReader:_pidAlive(pid)
    return self:_pidState(pid) == "running"
end

function TTSReader:_playbackPollInterval()
    local playback = self.playback
    if playback and playback.paused then
        return 1.2
    end
    if playback and playback.native_spawned then
        return 0.75
    end
    return 0.9
end

function TTSReader:_startProcess(command)
    self.shell_player_seq = (self.shell_player_seq or 0) + 1
    local status_path = string.format(
        "/tmp/ttsreader-player-%d-%d.status",
        os.time(),
        self.shell_player_seq
    )
    local runner = table.concat({
        "rm -f " .. shellQuote(status_path) .. " " .. shellQuote(status_path .. ".tmp"),
        "(" .. command .. ") >/dev/null 2>&1",
        "rc=$?",
        "printf '%s\\n' \"$rc\" >" .. shellQuote(status_path .. ".tmp"),
        "mv -f " .. shellQuote(status_path .. ".tmp") .. " " .. shellQuote(status_path),
        "exit \"$rc\"",
    }, "\n")
    local pid = tonumber(firstLine("(sh -c " .. shellQuote(runner) .. " >/dev/null 2>&1 & echo $!)"))
    if pid then
        self.shell_player_status_paths = self.shell_player_status_paths or {}
        self.shell_player_status_paths[tostring(pid)] = status_path
    else
        removeFile(status_path)
        removeFile(status_path .. ".tmp")
    end
    return pid
end

function TTSReader:_shellPlayerStatus(pid)
    local paths = self.shell_player_status_paths
    local status_path = paths and paths[tostring(pid)]
    if not status_path then
        return nil
    end
    local code = tonumber(readFile(status_path):match("(%-?%d+)"))
    if not code then
        return nil
    end
    paths[tostring(pid)] = nil
    removeFile(status_path)
    removeFile(status_path .. ".tmp")
    if code == 0 then
        return "exited", 0
    end
    return "failed", -math.max(1, math.abs(code))
end

function TTSReader:_cleanupShellPlayerStatus(pid)
    local paths = self.shell_player_status_paths
    local status_path = paths and paths[tostring(pid)]
    if not status_path then
        return
    end
    paths[tostring(pid)] = nil
    UIManager:scheduleIn(1.0, function()
        removeFile(status_path)
        removeFile(status_path .. ".tmp")
    end)
end

function TTSReader:_newPlaybackVolumeControlPath()
    self.volume_control_seq = (self.volume_control_seq or 0) + 1
    return string.format("/tmp/ttsreader-volume-%d-%d.ctl", os.time(), self.volume_control_seq)
end

function TTSReader:_writePlaybackVolumeControlPath(path, volume)
    if not path or path == "" then
        return false
    end
    local tmp = path .. ".tmp"
    local ok = writeFile(tmp, Engine.formatPlaybackNumber(volume) .. "\n")
    if ok then
        ok = os.rename(tmp, path) == true
    end
    if not ok then
        removeFile(tmp)
    end
    return ok
end

function TTSReader:_writePlaybackVolumeControl(volume)
    local playback = self.playback
    return playback and self:_writePlaybackVolumeControlPath(playback.volume_control_path, volume)
end

function TTSReader:_cleanupPlaybackVolumeControl(path)
    if not path or path == "" then
        return
    end
    UIManager:scheduleIn(1.0, function()
        removeFile(path)
        removeFile(path .. ".tmp")
    end)
end

function TTSReader:_startNativePlayer(player, path, speed, seek_seconds, volume, volume_control_path)
    if not Engine.isNativePlayer(player) then
        return nil
    end
    local native = self:_nativePlayerLib()
    if not native then
        logger.warn("ttsreader native player helper unavailable, falling back to shell spawn")
        return nil
    end
    logger.info("ttsreader native player spawn:", player, "speed", tostring(speed), "seek", tostring(seek_seconds or 0), "volume", tostring(volume or 1), "volume_control", tostring(volume_control_path or ""))
    local pid = tonumber(native.ttsreader_player_spawn_control(
        player,
        path,
        self:_audioDevice(),
        tonumber(speed) or 1,
        tonumber(seek_seconds) or 0,
        tonumber(volume) or 1,
        volume_control_path
    ))
    if pid and pid > 0 then
        return pid
    end
    return false
end

function TTSReader:_reapNativePid(pid, attempts)
    pid = tonumber(pid)
    attempts = tonumber(attempts) or 0
    if not pid then
        return
    end
    local native = self:_nativePlayerLib()
    if not native then
        return
    end
    local status = tonumber(native.ttsreader_player_reap(pid))
    if status == 0 and attempts > 0 then
        UIManager:scheduleIn(0.12, function()
            self:_reapNativePid(pid, attempts - 1)
        end)
    end
end

function TTSReader:_killPlaybackProcess()
    if self.playback_poll then
        UIManager:unschedule(self.playback_poll)
        self.playback_poll = nil
    end
    if self.playback and self.playback.pid then
        local pid = self.playback.pid
        local native_spawned = self.playback.native_spawned
        local volume_control_path = self.playback.volume_control_path
        self:_signalPid(pid, SIGTERM)
        self.playback.pid = nil
        self.playback.native_spawned = nil
        self.playback.volume_control_path = nil
        self:_cleanupPlaybackVolumeControl(volume_control_path)
        if native_spawned then
            self:_reapNativePid(pid, 8)
        else
            self:_cleanupShellPlayerStatus(pid)
        end
    end
end

function TTSReader:_playbackRetryKey()
    local playback = self.playback
    if not playback then
        return ""
    end
    return tostring(playback.page or 0) .. ":" .. tostring(playback.segment_index or 1)
end

function TTSReader:_beginBluetoothReadyGate(status, refresh_audio, ready_callback, failed_callback)
    local playback = self.playback
    if not playback or not playback.active or not self:_hasBluetoothAudio() then
        return false
    end

    playback.bluetooth_wait_token = (playback.bluetooth_wait_token or 0) + 1
    local token = playback.bluetooth_wait_token
    playback.bluetooth_status = status or _("connecting")
    self:_showPlaybackControls()

    if not self:_startBluetoothConnect(true, refresh_audio) then
        if failed_callback then
            failed_callback()
        end
        return true
    end

    local warmup = clamp(tonumber(self.config.bluetooth_warmup_seconds) or Engine.defaults.bluetooth_warmup_seconds, 0.6, 3.0)
    local deadline = socket.gettime() + Engine.bluetoothReadyGateSeconds(warmup)
    local function poll()
        if self.playback ~= playback
            or not playback.active
            or playback.bluetooth_wait_token ~= token
        then
            return
        end

        if self:_bluetoothRecentlyReady() then
            playback.bluetooth_wait_token = nil
            if ready_callback then
                ready_callback()
            end
            return
        end

        local now = socket.gettime()
        if now < deadline and (self.bluetooth_connect_job or (self.bluetooth_connect_until and now < self.bluetooth_connect_until)) then
            UIManager:scheduleIn(0.35, poll)
            return
        end

        playback.bluetooth_wait_token = nil
        self:_invalidateBluetoothReady()
        if failed_callback then
            failed_callback()
        end
    end
    UIManager:scheduleIn(0.35, poll)
    return true
end

function TTSReader:_scheduleBluetoothRetry(status_code, force_retry)
    local playback = self.playback
    if not playback or not playback.active or (not force_retry and not playback.native_spawned) or not self:_hasBluetoothAudio() then
        return false
    end
    self:_invalidateBluetoothReady()

    local key = self:_playbackRetryKey()
    if playback.bluetooth_retry_key ~= key then
        playback.bluetooth_retry_key = key
        playback.bluetooth_retry_count = 0
    end
    local limit = math.max(0, tonumber(self.config.bluetooth_retry_limit) or Engine.defaults.bluetooth_retry_limit)
    if (playback.bluetooth_retry_count or 0) >= limit then
        playback.bluetooth_status = _("reconnect failed")
        self:_showPlaybackControls()
        self:_rememberPlaybackLocation()
        self:stopPlayback(false)
        self:_show(T(_("Bluetooth audio stopped. Reconnect headphones and tap Play / resume audio. Code %1"), tostring(status_code or "")), 8)
        return true
    end

    local elapsed = self:_playbackElapsed()
    playback.bluetooth_retry_count = (playback.bluetooth_retry_count or 0) + 1
    playback.segment_audio_offset = elapsed
    playback.segment_started_at = nil
    playback.pause_started_at = nil
    playback.paused = false
    playback.bluetooth_status = T(
        _("reconnecting %1/%2"),
        tostring(playback.bluetooth_retry_count),
        tostring(limit)
    )
    self:_beginBluetoothReadyGate(playback.bluetooth_status, true, function()
        if self.playback == playback and playback.active and not playback.pid then
            playback.bluetooth_status = _("starting audio")
            self:_showPlaybackControls()
            self:_playCurrentSegment(elapsed)
        end
    end, function()
        if self.playback == playback and playback.active then
            if playback.bluetooth_status ~= _("not reachable")
                and playback.bluetooth_status ~= _("pairing issue")
                and playback.bluetooth_status ~= _("bt stack failed")
                and playback.bluetooth_status ~= _("connect timeout")
            then
                playback.bluetooth_status = _("reconnect failed")
            end
            self:_showPlaybackControls()
            self:_rememberPlaybackLocation()
            self:stopPlayback(false)
            self:_show(_("Bluetooth audio reconnect failed. Wake the headphones and tap Play / resume audio."), 8)
        end
    end)
    return true
end

function TTSReader:_handlePlaybackFailure(status_code)
    self:_invalidateBluetoothReady()
    if self:_scheduleBluetoothRetry(status_code) then
        return
    end
    self:_rememberPlaybackLocation()
    self:stopPlayback(false)
    self:_show(_("Audio player stopped unexpectedly. Tap Play / resume audio to continue."), 8)
end

function TTSReader:_playPath(path, done_callback, seek_seconds)
    local speed = self:_playbackSpeed()
    local volume = self:_playbackVolume()
    local player = self:_detectPlayer(speed)
    if not player then
        self:stopPlayback(false)
        self:_show(_("Bundled ttsreader-play was not found, and no fallback audio player is available."), 10)
        return
    end
    local bluetooth_audio = self:_hasBluetoothAudio()
    if bluetooth_audio then
        local refresh_audio = self:_bluetoothNeedsRefresh()
        if self:_bluetoothRecentlyReady() and not refresh_audio then
            self.playback.bluetooth_status = _("ready")
        else
            local playback = self.playback
            local key = tostring(path) .. ":" .. tostring(tonumber(seek_seconds) or 0) .. ":" .. tostring(refresh_audio)
            if playback
                and playback.active
                and not playback.pid
            then
                playback.bluetooth_warmup_key = key
                self:_beginBluetoothReadyGate(refresh_audio and _("refreshing") or _("connecting"), refresh_audio, function()
                    if self.playback == playback and playback.active and not playback.pid then
                        playback.bluetooth_status = _("starting audio")
                        playback.bluetooth_warmup_key = nil
                        self:_showPlaybackControls()
                        self:_playPath(path, done_callback, seek_seconds)
                    end
                end, function()
                    if self.playback == playback and playback.active and not playback.pid then
                        if not playback.bluetooth_status
                            or playback.bluetooth_status == _("connecting")
                            or playback.bluetooth_status == _("refreshing")
                        then
                            playback.bluetooth_status = _("connect failed")
                        end
                        playback.bluetooth_warmup_key = nil
                        playback.ready_to_play = true
                        playback.prepared_seek_seconds = tonumber(seek_seconds) or 0
                        playback.segment_audio_offset = tonumber(seek_seconds) or 0
                        playback.segment_started_at = nil
                        self:_showPlaybackControls()
                        self:_show(_("Bluetooth headphones are not connected. Wake them, then tap Play."), 8)
                    end
                end)
                return
            end
            self.playback.bluetooth_status = refresh_audio and _("refreshing") or _("connecting")
            self:_showPlaybackControls()
            self:_startBluetoothConnect(true, refresh_audio)
        end
    end
    local volume_control_path
    if Engine.isNativePlayer(player) then
        volume_control_path = self:_newPlaybackVolumeControlPath()
        if not self:_writePlaybackVolumeControlPath(volume_control_path, volume) then
            logger.warn("ttsreader could not create native volume control:", volume_control_path)
            volume_control_path = nil
        end
    end
    local command, info = self:_playerCommand(player, path, speed, seek_seconds, volume, volume_control_path)
    local native_spawned = false
    local pid = nil
    local native_pid = self:_startNativePlayer(player, path, speed, seek_seconds, volume, volume_control_path)
    if native_pid == false then
        self:_cleanupPlaybackVolumeControl(volume_control_path)
        logger.warn("ttsreader native player failed to start")
        self:stopPlayback(false)
        self:_show(_("Could not start bundled native audio player."))
        return
    elseif native_pid then
        pid = native_pid
        native_spawned = true
    else
        pid = self:_startProcess(command)
    end
    if not pid then
        self:_cleanupPlaybackVolumeControl(volume_control_path)
        logger.warn("ttsreader audio player start failed:", player)
        self:stopPlayback(false)
        self:_show(_("Could not start audio player."))
        return
    end
    self.playback.pid = pid
    self.playback.native_spawned = native_spawned
    self.playback.volume_control_path = volume_control_path
    self.playback.bluetooth_warmup_key = nil
    self.playback.bluetooth_warmup_started_at = nil
    self.playback.player = player
    self.playback.speed = speed
    self.playback.effective_speed = info.effective_speed or speed
    self.playback.volume = volume
    self.playback.effective_volume = info.effective_volume or volume
    self.playback.speed_supported = info.speed_supported
    self.playback.seek_supported = info.seek_supported
    self.playback.volume_supported = info.volume_supported
    self.playback.live_volume_supported = info.live_volume_supported
    self.playback.paused = false
    self.playback.pause_started_at = nil
    self.playback.segment_audio_offset = info.seek_supported and (tonumber(seek_seconds) or 0) or 0
    self.playback.segment_started_at = socket.gettime()
    self.playback.current_line = self:_currentPlaybackLine()
    self.playback.bluetooth_status = bluetooth_audio and _("streaming") or nil
    if bluetooth_audio then
        self:_markBluetoothReady(12)
        self:_markBluetoothAudioActive()
    end
    self:_showPlaybackControls(true)
    self:_schedulePlaybackIndicator()
    self.playback_poll = function()
        local state, status_code = self:_pidState(pid)
        if state == "running" then
            UIManager:scheduleIn(self:_playbackPollInterval(), self.playback_poll)
        else
            if self.playback and self.playback.pid == pid then
                local volume_control_path = self.playback.volume_control_path
                self.playback.pid = nil
                self.playback.volume_control_path = nil
                self:_cleanupPlaybackVolumeControl(volume_control_path)
                if state == "failed" then
                    self:_handlePlaybackFailure(status_code)
                else
                    if bluetooth_audio then
                        self:_markBluetoothAudioActive()
                    end
                    if self.playback then
                        self.playback.bluetooth_status = bluetooth_audio and _("streaming") or nil
                    end
                    done_callback()
                end
            end
        end
    end
    UIManager:scheduleIn(self:_playbackPollInterval(), self.playback_poll)
end

function TTSReader:_startBluetoothConnect(silent, force_refresh)
    local command = self:_bluetoothConnectCommand(force_refresh)
    if not command then
        if not silent then
            self:_show(_("No Bluetooth headphones are saved. Use Audio reading > Bluetooth headphones > Scan and pair headphones."), 8)
        end
        return false
    end
    self:_cancelBluetoothIdleShutdown()

    if not force_refresh and self:_bluetoothRecentlyReady() then
        if not silent then
            self:_show(_("Bluetooth headphones are ready."))
        end
        if not self.playback or not self.playback.pid then
            self:_scheduleBluetoothIdleShutdown()
        end
        return true
    end

    local now = socket.gettime()
    local warmup = clamp(tonumber(self.config.bluetooth_warmup_seconds) or Engine.defaults.bluetooth_warmup_seconds, 0.6, 3.0)
    local connect_timeout = Engine.bluetoothConnectTimeoutSeconds(warmup)
    if self.bluetooth_connect_until and now < self.bluetooth_connect_until then
        if not silent then
            self:_show(_("Bluetooth reconnect is already running."))
        end
        return true
    end
    self.bluetooth_connect_until = now + Engine.bluetoothReadyGateSeconds(warmup)
    self.bluetooth_connect_job = self:_startAsyncCommand(
        command,
        "bt-connect",
        connect_timeout
    )
    self:_pollAsyncJob(self.bluetooth_connect_job, function(output, status)
        self.bluetooth_connect_job = nil
        self.bluetooth_connect_until = nil
        local text = tostring(output or "")
        local using_default_connect = self:_bluetoothMac() ~= ""
            and not (self.config.bluetooth_connect_cmd and self.config.bluetooth_connect_cmd ~= "")
        local connected = Engine.bluetoothInfoConnected(text)
        if connected or (not using_default_connect and status == 0) then
            self:_markBluetoothReady(12)
            if self.playback then
                self.playback.bluetooth_status = _("ready")
                self:_showPlaybackControls()
            end
            if not silent then
                self:_show(_("Bluetooth headphones are ready."))
            end
        else
            self:_invalidateBluetoothReady()
            local failure_status = Engine.bluetoothConnectFailureStatus(text, status, BT_TIMEOUT_MARKER, BT_STACK_FAILED_MARKER)
            if self.playback then
                self.playback.bluetooth_status = _(failure_status)
                self:_showPlaybackControls()
            end
            if not silent then
                if failure_status == "not reachable" then
                    self:_show(_("Bluetooth headphones were not found. Wake them, keep them near the Kobo, then try again."), 8)
                elseif failure_status == "pairing issue" then
                    self:_show(_("Bluetooth pairing needs repair. Forget the headphones, then scan and pair again."), 8)
                elseif failure_status == "bt stack failed" then
                    self:_show(_("Bluetooth stack could not start. Restart KOReader, then try again."), 8)
                else
                    self:_show(_("Bluetooth reconnect did not finish. Put headphones near the Kobo and try again."), 6)
                end
            end
        end
        if not self.playback or not self.playback.pid then
            self:_scheduleBluetoothIdleShutdown()
        end
    end, function()
        self.bluetooth_connect_job = nil
        self.bluetooth_connect_until = nil
        self:_invalidateBluetoothReady()
        if self.playback then
            self.playback.bluetooth_status = _("connect timeout")
            self:_showPlaybackControls()
        end
        if not silent then
            self:_show(_("Bluetooth reconnect timed out."), 6)
        end
        if not self.playback or not self.playback.pid then
            self:_scheduleBluetoothIdleShutdown()
        end
    end, 0.35)
    if not silent then
        self:_show(_("Bluetooth reconnect started."))
    end
    return true
end

function TTSReader:connectBluetooth()
    self:_refreshConfig()
    self:_startBluetoothConnect(false)
end

function TTSReader:_scanBluetoothDevices()
    local script = self:_bluetoothScanScript()
    local output = self:_runBluetoothScript(script, 24)
    local text = tostring(output or "")
    return Engine.parseBluetoothDevices(output),
        text:find(BT_TIMEOUT_MARKER, 1, true) ~= nil,
        text:find(BT_STACK_FAILED_MARKER, 1, true) ~= nil
end

function TTSReader:_bluetoothScanScript()
    return self:_bluetoothScriptPrefix() .. [[
ensure_bt_controller || exit 1
scan_log="${TMPDIR:-/tmp}/ttsreader-bt-scan-$$.log"
rm -f "$scan_log"
scan_cleanup() {
    bt_scan_off_quiet
    rm -f "$scan_log"
}
trap 'scan_cleanup; exit 124' INT TERM
(
    printf 'power on\n'
    sleep 0.3
    printf 'agent on\n'
    sleep 0.3
    printf 'default-agent\n'
    sleep 0.3
    printf 'pairable on\n'
    sleep 0.3
    printf 'scan on\n'
    sleep 10
    printf 'scan off\n'
    sleep 0.4
    printf 'devices\n'
    sleep 0.3
    printf 'quit\n'
) | bt 14 >"$scan_log" 2>&1
scan_rc=$?
bt_scan_off_quiet
cat "$scan_log" 2>/dev/null
rm -f "$scan_log"
if [ "$scan_rc" -eq 124 ]; then
    echo ]] .. BT_TIMEOUT_MARKER .. [[
fi
bt 4 devices 2>/dev/null
echo ::PAIRED::
bt 4 paired-devices 2>/dev/null
]]
end

function TTSReader:_bluetoothKnownDevicesScript()
    return self:_bluetoothScriptPrefix() .. [[
ensure_bt_controller || exit 1
bt 3 devices 2>/dev/null || true
echo ::PAIRED::
bt 3 paired-devices 2>/dev/null || true
]]
end

function TTSReader:_bluetoothDeviceLabel(device)
    local name = device.name and device.name ~= "" and device.name or _("Unknown device")
    local state = device.paired and _("paired") or _("new")
    if Engine.bluetoothMac(self.config.bluetooth_mac) == device.mac then
        state = _("saved")
    end
    return T("%1\n%2 (%3)", name, device.mac, state)
end

function TTSReader:_showBluetoothScanResults(devices, timed_out, stack_failed, known_only)
    local buttons = {}
    local dialog

    if #devices == 0 then
        buttons = {
            {
                {
                    text = _("Scan again"),
                    callback = function()
                        UIManager:close(dialog)
                        self:scanBluetoothHeadphones(true)
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        }
        local title = stack_failed
            and _("Bluetooth controller could not start.\nRestart KOReader, keep Wi-Fi enabled, then scan again.")
            or timed_out
            and _("Bluetooth scan timed out.\nPut your headphones in pairing mode, keep them near the Kobo, then scan again.")
            or _("No Bluetooth devices found.\nPut your headphones in pairing mode, keep them near the Kobo, then scan again.")
        dialog = ButtonDialog:new{
            title = title,
            width = math.floor(Screen:getWidth() * 0.92),
            buttons = buttons,
        }
        UIManager:show(dialog)
        return
    end

    for i = 1, math.min(#devices, 8) do
        local device = devices[i]
        buttons[#buttons + 1] = {
            {
                text = self:_bluetoothDeviceLabel(device),
                callback = function()
                    UIManager:close(dialog)
                    self:pairBluetoothHeadphones(device.mac, device.name)
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = known_only and _("Scan for new") or _("Scan again"),
            callback = function()
                UIManager:close(dialog)
                self:scanBluetoothHeadphones(known_only == true)
            end,
        },
        {
            text = _("Close"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
    }

    dialog = ButtonDialog:new{
        title = known_only and _("Saved Bluetooth headphones") or _("Select Bluetooth headphones"),
        width = math.floor(Screen:getWidth() * 0.92),
        rows_per_page = 6,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function TTSReader:_startBluetoothDiscoveryScan()
    self:_show(_("Scanning Bluetooth. Put headphones in pairing mode and keep them near the Kobo."), 5)
    local job = self:_startAsyncCommand(
        self:_bluetoothScriptCommand(self:_bluetoothScanScript(), 18),
        "bt-scan",
        24
    )
    self.bluetooth_scan_job = job
    self:_pollAsyncJob(job, function(output)
        self.bluetooth_scan_active = false
        self.bluetooth_scan_job = nil
        local text = tostring(output or "")
        local devices = Engine.parseBluetoothDevices(text)
        local timed_out = text:find(BT_TIMEOUT_MARKER, 1, true) ~= nil
        local stack_failed = text:find(BT_STACK_FAILED_MARKER, 1, true) ~= nil
        self:_showBluetoothScanResults(devices, timed_out, stack_failed, false)
        self:_scheduleBluetoothIdleShutdown()
    end, function()
        self.bluetooth_scan_active = false
        self.bluetooth_scan_job = nil
        logger.warn("ttsreader bluetooth scan timed out")
        self:_showBluetoothScanResults({}, true, false, false)
        self:_scheduleBluetoothIdleShutdown()
    end, 0.5)
end

function TTSReader:scanBluetoothHeadphones(force_discovery)
    if self.bluetooth_scan_active then
        self:_show(_("Bluetooth scan is already running."))
        return
    end
    if not self:_requireBluetoothctl() then
        return
    end

    self:_cancelBluetoothIdleShutdown()
    self.bluetooth_scan_active = true
    if force_discovery ~= true then
        self:_show(_("Checking saved Bluetooth headphones."), 3)
        local job = self:_startAsyncCommand(
            self:_bluetoothScriptCommand(self:_bluetoothKnownDevicesScript(), 8),
            "bt-known",
            12
        )
        self.bluetooth_scan_job = job
        self:_pollAsyncJob(job, function(output)
            self.bluetooth_scan_active = false
            self.bluetooth_scan_job = nil
            local text = tostring(output or "")
            local devices = Engine.parseBluetoothDevices(text)
            local stack_failed = text:find(BT_STACK_FAILED_MARKER, 1, true) ~= nil
            if #devices > 0 or stack_failed then
                self:_showBluetoothScanResults(devices, false, stack_failed, true)
                self:_scheduleBluetoothIdleShutdown()
            else
                self:scanBluetoothHeadphones(true)
            end
        end, function()
            self.bluetooth_scan_active = false
            self.bluetooth_scan_job = nil
            self:scanBluetoothHeadphones(true)
        end, 0.35)
        return
    end

    self:_startBluetoothDiscoveryScan()
end

function TTSReader:_saveBluetoothHeadphones(mac)
    mac = Engine.bluetoothMac(mac)
    if mac == "" then
        return false
    end
    self:_refreshConfig()
    if self:_bluetoothMac() ~= mac then
        self:_invalidateBluetoothReady()
    end
    self.config.bluetooth_mac = mac
    self.config.bluetooth_connect_cmd = ""
    self:_saveConfig()
    return true
end

function TTSReader:pairBluetoothHeadphones(mac, name)
    mac = Engine.bluetoothMac(mac)
    if mac == "" then
        self:_show(_("Invalid Bluetooth device address."))
        return
    end
    if not self:_requireBluetoothctl() then
        return
    end

    self:_cancelBluetoothIdleShutdown()
    self:_show(T(_("Connecting to %1..."), name and name ~= "" and name or mac), 4)
    local quoted = shellQuote(mac)
    local script = self:_bluetoothScriptPrefix() .. table.concat({
        "ensure_bluealsa || exit 1",
        "bt 3 power on >/dev/null 2>&1 || true",
        "bt 3 agent on >/dev/null 2>&1 || true",
        "bt 3 default-agent >/dev/null 2>&1 || true",
        "bt 3 pairable on >/dev/null 2>&1 || true",
        "bt 12 pair " .. quoted .. " >/tmp/ttsreader-bluetooth.log 2>&1 || true",
        "bt 5 trust " .. quoted .. " >>/tmp/ttsreader-bluetooth.log 2>&1 || true",
        "bt 8 connect " .. quoted .. " >>/tmp/ttsreader-bluetooth.log 2>&1 || true",
        "echo ::INFO::",
        "bt 4 info " .. quoted .. " 2>/dev/null || true",
    }, "\n")
    local job = self:_startAsyncCommand(
        self:_bluetoothScriptCommand(script, 30),
        "bt-pair",
        36
    )
    self.bluetooth_pair_job = job
    self:_pollAsyncJob(job, function(output)
        self.bluetooth_pair_job = nil
        local info_output = tostring(output or ""):match("::INFO::%s*(.*)") or output
        local info = self:_parseBluetoothDeviceInfo(mac, info_output)
        if info.connected or info.paired or info.trusted then
            self:_saveBluetoothHeadphones(mac)
            local state = info.connected and _("connected") or _("saved")
            self:_show(T(_("Bluetooth headphones %1: %2"), state, info.name or mac), 8)
        else
            self:_show(_("Bluetooth pairing did not complete. Put the headphones back in pairing mode and scan again."), 9)
        end
        self:_scheduleBluetoothIdleShutdown()
    end, function()
        self.bluetooth_pair_job = nil
        logger.warn("ttsreader bluetooth pair timed out:", mac)
        self:_show(_("Bluetooth pairing timed out. Put the headphones back in pairing mode and scan again."), 9)
        self:_scheduleBluetoothIdleShutdown()
    end, 0.5)
end

function TTSReader:forgetBluetoothHeadphones()
    self:_refreshConfig()
    local mac = Engine.bluetoothMac(self.config.bluetooth_mac)
    if mac == "" then
        self:_show(_("No Bluetooth headphones are saved."))
        return
    end
    local info = self:_bluetoothDeviceInfo(mac)
    UIManager:show(ConfirmBox:new{
        text = T(_("Forget Bluetooth headphones?\n%1\n%2"), info.name or mac, mac),
        ok_text = _("Forget"),
        ok_callback = function()
            self:_cancelBluetoothIdleShutdown()
            local quoted = shellQuote(mac)
            local script = self:_bluetoothScriptPrefix() .. table.concat({
                "ensure_bt_controller >/dev/null 2>&1 || true",
                "bt 5 disconnect " .. quoted .. " >/tmp/ttsreader-bluetooth.log 2>&1 || true",
                "bt 5 remove " .. quoted .. " >>/tmp/ttsreader-bluetooth.log 2>&1 || true",
            }, "\n")
            self:_runBluetoothScript(script, 10)
            self:_refreshConfig()
            if Engine.bluetoothMac(self.config.bluetooth_mac) == mac then
                self.config.bluetooth_mac = ""
                self.config.bluetooth_connect_cmd = ""
                self:_saveConfig()
            end
            self:_invalidateBluetoothReady()
            self:_show(_("Bluetooth headphones forgotten."))
            self:_scheduleBluetoothIdleShutdown()
        end,
    })
end

function TTSReader:showBluetoothStatus()
    self:_refreshConfig()
    local mac = Engine.bluetoothMac(self.config.bluetooth_mac)
    if mac == "" then
        self:_show(_("No Bluetooth headphones are saved. Scan and pair from the Kobo menu."), 8)
        return
    end
    self:_cancelBluetoothIdleShutdown()
    local info = self:_bluetoothDeviceInfo(mac)
    local rows = {
        _("Bluetooth headphones"),
        T(_("Name: %1"), info.name or mac),
        T(_("Address: %1"), mac),
        T(_("Connected: %1"), info.connected and _("yes") or _("no")),
        T(_("Paired: %1"), info.paired and _("yes") or _("no")),
        T(_("Trusted: %1"), info.trusted and _("yes") or _("no")),
    }
    self:_show(table.concat(rows, "\n"), 10)
    self:_scheduleBluetoothIdleShutdown()
end

function TTSReader:_bluetoothMenuItems()
    self:_refreshConfig()
    return {
        {
            text = _("Kulaklik tara ve esle"),
            keep_menu_open = true,
            callback = function()
                self:scanBluetoothHeadphones()
            end,
        },
        {
            text = _("Kayitli kulakliga baglan"),
            enabled_func = function()
                return Engine.hasBluetoothAudio(self.config)
            end,
            keep_menu_open = true,
            callback = function()
                self:connectBluetooth()
            end,
        },
        {
            text = _("Bluetooth durumu"),
            keep_menu_open = true,
            callback = function()
                self:showBluetoothStatus()
            end,
        },
        {
            text = _("Kayitli kulakligi sil"),
            enabled_func = function()
                return Engine.hasBluetoothAudio(self.config)
            end,
            keep_menu_open = true,
            callback = function()
                self:forgetBluetoothHeadphones()
            end,
        },
    }
end

function TTSReader:startPlayback(mode)
    if not self:_hasDocument() then
        self:_show(_("Open a book first."))
        return
    end
    if self.playback and self.playback.active then
        self:_show(_("Audio playback is already running."))
        return
    end
    if not self:_narrationVoice() then
        self:chooseNarrationLanguage(function()
            self:startPlayback(mode)
        end)
        return
    end

    self:_cancelBluetoothIdleShutdown()
    self:_refreshConfig()
    local book_dir = self:_bookDir()
    local resume = mode ~= "current" and self.resume_playback and self.resume_playback.book_dir == book_dir and self.resume_playback
    local start_page = resume and resume.page or self:_currentPage()
    local page_count = self:_pageCount()
    self.playback = {
        active = true,
        book_dir = book_dir,
        page = start_page,
        page_count = page_count,
        cache_index = Engine.buildCacheStatusIndex(book_dir, 1, page_count),
        segment_index = resume and resume.segment_index or 1,
        resume_offset = resume and resume.elapsed or 0,
        segment_entries = nil,
        current_entry = nil,
        page_lines = nil,
        speed = Engine.normalizePlaybackSpeed(self.config.playback_speed),
        effective_speed = Engine.normalizePlaybackSpeed(self.config.playback_speed),
        volume = Engine.normalizePlaybackVolume(self.config.playback_volume),
        effective_volume = Engine.normalizePlaybackVolume(self.config.playback_volume),
        segment_audio_offset = 0,
        paused = false,
        ready_to_play = true,
        prepared_seek_seconds = resume and resume.elapsed or 0,
        bluetooth_status = self:_bluetoothIdleStatus(),
        bluetooth_retry_key = nil,
        bluetooth_retry_count = 0,
        line_timepoint_index = nil,
        next_indicator_paint_at = nil,
    }
    logger.info("ttsreader playback start page:", tostring(start_page), "mode:", tostring(mode or "resume"))
    PluginShare.pause_auto_suspend = true
    self:_ensureHeadsetInputOpen()
    self:_showPlaybackControls()
    self:_playNextPage()
end

function TTSReader:_loadPageLines(book_dir, page)
    local lines = Engine.readPageLines(book_dir, page)
    if lines and #lines > 0 then
        return lines
    end
    lines = Engine.wrapLongLines(
        Engine.extractPageLines(self.ui.document, page),
        (tonumber(self.config.request_char_limit) or Engine.defaults.request_char_limit) - 96
    )
    if #lines > 0 then
        Engine.writePageLines(book_dir, page, lines)
    end
    return lines
end

function TTSReader:_fillMissingEntryMeta(entries, lines)
    local total_lines = #lines
    local count = #entries
    if total_lines == 0 or count == 0 then
        return
    end
    for i, entry in ipairs(entries) do
        if not entry.meta then
            local first_line = math.floor((i - 1) * total_lines / count) + 1
            local last_line = math.floor(i * total_lines / count)
            entry.meta = {
                first_line = first_line,
                last_line = math.max(first_line, last_line),
                total_lines = total_lines,
                timepoints = {},
            }
        end
    end
end

function TTSReader:_playNextPage()
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    if playback.page > playback.page_count then
        playback.finished = true
        self:stopPlayback(false)
        self:_show(_("Hazir ses bitti."))
        return
    end

    local next_page, entries, skipped_pages, blocking_status = Engine.nextPlayableSegmentEntries(
        playback.book_dir,
        playback.page,
        playback.page_count,
        self.config,
        playback.cache_index
    )
    if not entries and playback.cache_index then
        playback.cache_index = Engine.buildCacheStatusIndex(playback.book_dir, 1, playback.page_count)
        next_page, entries, skipped_pages, blocking_status = Engine.nextPlayableSegmentEntries(
            playback.book_dir,
            playback.page,
            playback.page_count,
            self.config,
            playback.cache_index
        )
    end
    if not entries then
        if blocking_status and blocking_status.state == "finished" then
            playback.finished = true
            self:stopPlayback(false)
            self:_show(_("Hazir ses bitti."))
            return
        end
        self:stopPlayback(false)
        local missing_page = blocking_status and blocking_status.page or playback.page
        self:_show(T(_("Sayfa %1 icin hazir ses yok. Once TTS onbelleginden indir."), missing_page), 8)
        return
    end
    if next_page ~= playback.page then
        playback.page = next_page
        playback.segment_index = 1
        playback.resume_offset = nil
        if skipped_pages and skipped_pages > 0 then
            logger.info("ttsreader skipped textless pages before playback:", tostring(skipped_pages))
        end
    end
    playback.page_lines = self:_loadPageLines(playback.book_dir, playback.page)
    self:_fillMissingEntryMeta(entries, playback.page_lines)
    playback.segment_entries = entries
    local resume_offset = playback.resume_offset
    playback.segment_index = resume_offset and playback.segment_index or 1
    playback.segment_index = clamp(playback.segment_index or 1, 1, #entries)
    playback.current_entry = entries[playback.segment_index]
    playback.current_line = playback.current_entry and playback.current_entry.meta and playback.current_entry.meta.first_line
    playback.line_timepoint_index = nil
    playback.next_indicator_paint_at = nil
    self.ui:handleEvent(Event:new("GotoPage", playback.page))
    self:_showPlaybackControls()
    playback.resume_offset = nil
    if playback.ready_to_play then
        self:_prepareCurrentSegment(resume_offset)
    else
        self:_playCurrentSegment(resume_offset)
    end
end

function TTSReader:_prepareCurrentSegment(seek_seconds)
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    local entry = playback.segment_entries and playback.segment_entries[playback.segment_index]
    if not entry then
        playback.page = playback.page + 1
        self:_playNextPage()
        return
    end
    seek_seconds = math.max(0, tonumber(seek_seconds) or 0)
    playback.current_entry = entry
    playback.ready_to_play = true
    playback.prepared_seek_seconds = seek_seconds
    playback.segment_started_at = nil
    playback.segment_audio_offset = seek_seconds
    playback.current_line = entry.meta and self:_setPlaybackLineAtElapsed(entry.meta, seek_seconds) or nil
    playback.next_indicator_paint_at = nil
    if self:_hasBluetoothAudio()
        and not self:_bluetoothRecentlyReady()
        and (not playback.bluetooth_status or playback.bluetooth_status == _("ready"))
    then
        playback.bluetooth_status = _("not connected")
    end
    self:_showPlaybackControls(true)
end

function TTSReader:playPreparedAudio()
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    if playback.pid then
        return
    end
    playback.ready_to_play = false
    local seek_seconds = playback.prepared_seek_seconds or playback.resume_offset or playback.segment_audio_offset or 0
    playback.prepared_seek_seconds = nil
    playback.resume_offset = nil
    self:_playCurrentSegment(seek_seconds)
end

function TTSReader:_playCurrentSegment(seek_seconds)
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    local entry = playback.segment_entries[playback.segment_index]
    if not entry then
        playback.page = playback.page + 1
        self:_playNextPage()
        return
    end
    playback.ready_to_play = false
    playback.prepared_seek_seconds = nil
    playback.current_entry = entry
    local retry_key = self:_playbackRetryKey()
    if playback.bluetooth_retry_key ~= retry_key then
        playback.bluetooth_retry_key = retry_key
        playback.bluetooth_retry_count = 0
    end
    seek_seconds = math.max(0, tonumber(seek_seconds) or 0)
    playback.current_line = entry.meta and self:_setPlaybackLineAtElapsed(entry.meta, seek_seconds) or nil
    playback.next_indicator_paint_at = nil
    playback.segment_started_at = nil
    playback.segment_audio_offset = seek_seconds
    self:_showPlaybackControls()
    self:_playPath(entry.path, function()
        if self.playback then
            self.playback.segment_index = self.playback.segment_index + 1
            self:_playCurrentSegment(0)
        end
    end, seek_seconds)
end

function TTSReader:stopPlayback(show_message)
    self:_rememberPlaybackLocation()
    logger.info("ttsreader playback stop")
    self:_killPlaybackProcess()
    self:_unschedulePlaybackIndicator()
    if self.playback then
        self.playback.active = false
        self.playback = nil
        self:_hidePlaybackControls()
        if not self.generation then
            PluginShare.pause_auto_suspend = false
        end
        if show_message ~= false then
            self:_show(_("Audio playback stopped."))
        end
    end
    if self:_hasBluetoothAudio() then
        self:_scheduleBluetoothIdleShutdown()
    end
end

function TTSReader:togglePlaybackPause()
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    if not playback.pid then
        self:playPreparedAudio()
        return
    end

    if playback.paused then
        self:_signalPid(playback.pid, SIGCONT)
        if playback.pause_started_at and playback.segment_started_at then
            playback.segment_started_at = playback.segment_started_at + (socket.gettime() - playback.pause_started_at)
        end
        playback.pause_started_at = nil
        playback.paused = false
    else
        self:_signalPid(playback.pid, SIGSTOP)
        playback.pause_started_at = socket.gettime()
        playback.paused = true
    end
    self:_reopenPlaybackControls()
end

function TTSReader:setPlaybackSpeed(speed)
    speed = Engine.normalizePlaybackSpeed(speed)
    self.config.playback_speed = speed
    self:_saveConfig()

    local playback = self.playback
    if not playback or not playback.active then
        self:_show(T(_("Audio speed set to %1"), Engine.speedLabel(speed)))
        return
    end

    local elapsed = self:_playbackElapsed()
    playback.speed = speed
    playback.effective_speed = speed
    if not playback.pid then
        self:_reopenPlaybackControls()
        return
    end
    self:_reopenPlaybackControls()
    self:_killPlaybackProcess()
    self:_playCurrentSegment(elapsed)
end

function TTSReader:cyclePlaybackSpeed()
    self:setPlaybackSpeed(Engine.nextPlaybackSpeed(self:_playbackSpeed()))
end

function TTSReader:_scheduleVolumeRestart(was_paused)
    local playback = self.playback
    if not playback or not playback.active or not playback.pid then
        return
    end
    playback.volume_restart_token = (playback.volume_restart_token or 0) + 1
    local token = playback.volume_restart_token
    playback.bluetooth_status = playback.bluetooth_status or (self:_hasBluetoothAudio() and _("streaming") or nil)
    UIManager:scheduleIn(0.55, function()
        if self.playback ~= playback
            or not playback.active
            or not playback.pid
            or playback.volume_restart_token ~= token
        then
            return
        end
        local elapsed = self:_playbackElapsed()
        self:_killPlaybackProcess()
        if was_paused or playback.paused then
            playback.paused = false
            playback.ready_to_play = true
            self:_prepareCurrentSegment(elapsed)
        else
            self:_playCurrentSegment(elapsed)
        end
    end)
end

function TTSReader:setPlaybackVolume(volume)
    volume = Engine.normalizePlaybackVolume(volume)
    self.config.playback_volume = volume
    self:_saveConfig()

    local playback = self.playback
    if not playback or not playback.active then
        self:_show(T(_("Audio volume set to %1"), Engine.volumeLabel(volume)))
        return
    end

    local was_paused = playback.paused
    playback.volume = volume
    playback.effective_volume = playback.volume_supported == false and 1.0 or volume
    if playback.pid and playback.volume_supported == false then
        self:_reopenPlaybackControls()
        self:_show(_("Current player cannot adjust volume."))
        return
    end
    if not playback.pid then
        self:_reopenPlaybackControls()
        return
    end
    self:_reopenPlaybackControls()
    if playback.pid and playback.volume_control_path and self:_writePlaybackVolumeControl(volume) then
        playback.volume_restart_token = (playback.volume_restart_token or 0) + 1
        playback.live_volume_supported = true
        return
    end
    self:_scheduleVolumeRestart(was_paused)
end

function TTSReader:adjustPlaybackVolume(direction)
    self:setPlaybackVolume(Engine.adjustPlaybackVolume(self:_playbackVolume(), direction))
end

function TTSReader:seekPlayback(delta)
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    if playback.pid and playback.seek_supported == false then
        self:_show(_("Current player cannot seek in audio."))
        return
    end

    local base = playback.pid and self:_playbackElapsed()
        or (playback.prepared_seek_seconds or playback.segment_audio_offset or 0)
    local elapsed = math.max(0, base + (tonumber(delta) or 0))
    self:_rememberPlaybackLocation()
    if not playback.pid then
        self:_prepareCurrentSegment(elapsed)
        return
    end
    self:_killPlaybackProcess()
    self:_playCurrentSegment(elapsed)
end

function TTSReader:goToPlaybackPage()
    local page
    if self.playback and self.playback.active then
        page = self.playback.page
    elseif self.resume_playback then
        page = self.resume_playback.page
    end
    if page then
        self.ui:handleEvent(Event:new("GotoPage", page))
        self:_show(T(_("Returned to audio page %1"), tostring(page)), 3)
    end
end

function TTSReader:continuePlaybackFromVisiblePage()
    local page = self:_visiblePage()
    if not page then
        return
    end
    local playback = self.playback
    if not playback or not playback.active then
        self.resume_playback = nil
        self:startPlayback("current")
        return
    end
    page = clamp(page, 1, playback.page_count or self:_pageCount())
    if page == playback.page then
        self:goToPlaybackPage()
        return
    end

    self:_rememberPlaybackLocation()
    self:_killPlaybackProcess()
    playback.page = page
    playback.segment_index = 1
    playback.resume_offset = 0
    playback.segment_entries = nil
    playback.current_entry = nil
    playback.page_lines = nil
    playback.segment_audio_offset = 0
    playback.prepared_seek_seconds = 0
    playback.segment_started_at = nil
    playback.pause_started_at = nil
    playback.paused = false
    playback.ready_to_play = false
    playback.current_line = nil
    playback.line_timepoint_index = nil
    playback.next_indicator_paint_at = nil
    playback.bluetooth_retry_key = nil
    playback.bluetooth_retry_count = 0
    self:_showPlaybackControls(true)
    self:_show(T(_("Bu sayfadan devam: %1"), tostring(page)), 3)
    self:_playNextPage()
end

function TTSReader:nextAudio()
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    self:_rememberPlaybackLocation()
    local was_ready = playback.ready_to_play or not playback.pid
    if playback.pid then
        self:_killPlaybackProcess()
    end
    playback.segment_index = (playback.segment_index or 1) + 1
    if was_ready then
        playback.ready_to_play = true
        self:_prepareCurrentSegment(0)
    else
        self:_playCurrentSegment(0)
    end
end

function TTSReader:previousAudio()
    local playback = self.playback
    if not playback or not playback.active then
        return
    end
    self:_rememberPlaybackLocation()
    local was_ready = playback.ready_to_play or not playback.pid
    if playback.pid then
        self:_killPlaybackProcess()
    end
    if (playback.segment_index or 1) > 1 then
        playback.segment_index = playback.segment_index - 1
        if was_ready then
            playback.ready_to_play = true
            self:_prepareCurrentSegment(0)
        else
            self:_playCurrentSegment(0)
        end
        return
    end
    if playback.page > 1 then
        playback.page = playback.page - 1
        playback.ready_to_play = was_ready
        self:_playNextPage()
    else
        playback.segment_index = 1
        if was_ready then
            playback.ready_to_play = true
            self:_prepareCurrentSegment(0)
        else
            self:_playCurrentSegment(0)
        end
    end
end

function TTSReader:_formatCacheBytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1048576 then
        return string.format("%.1f MB", bytes / 1048576)
    end
    if bytes >= 1024 then
        return string.format("%.0f KB", bytes / 1024)
    end
    return tostring(bytes) .. " B"
end

function TTSReader:_cacheStateLabel(state)
    if state == "complete" then
        return _("Hazir")
    elseif state == "partial" then
        return _("Kismi")
    elseif state == "skipped" then
        return _("Metin yok")
    end
    return _("Eksik")
end

function TTSReader:_partCacheSummaryText(summary)
    local parts = {
        T(_("%1 hazir"), Engine.percentLabel(summary.percent)),
        T(_("%1 eksik"), tostring(summary.missing or 0)),
    }
    if (tonumber(summary.partial) or 0) > 0 then
        parts[#parts + 1] = T(_("%1 kismi"), tostring(summary.partial))
    end
    if (tonumber(summary.skipped) or 0) > 0 then
        parts[#parts + 1] = T(_("%1 metinsiz"), tostring(summary.skipped))
    end
    return table.concat(parts, "  ")
end

function TTSReader:_pageCacheDetailText(status)
    if status.state == "missing" or status.state == "skipped" then
        return self:_cacheStateLabel(status.state)
    end
    return T(_("%1  %2/%3 parca  %4"),
        self:_cacheStateLabel(status.state),
        tostring(status.audio_count or 0),
        tostring(status.segment_count or 0),
        self:_formatCacheBytes(status.bytes))
end

function TTSReader:_buildTTSCachePartItems()
    local page_count = math.max(1, tonumber(self:_pageCount()) or 1)
    local chunk_size = math.max(1, tonumber(self.config.page_chunk_size) or Engine.defaults.page_chunk_size)
    local book_dir = self:_bookDir()
    local items = {}
    local totals = {
        total = 0,
        complete = 0,
        skipped = 0,
        partial = 0,
        missing = 0,
        bytes = 0,
    }

    local cache_index = Engine.buildCacheStatusIndex(book_dir, 1, page_count)
    local part = 1
    for start_page = 1, page_count, chunk_size do
        local end_page = math.min(page_count, start_page + chunk_size - 1)
        local summary = Engine.rangeCacheStatus(book_dir, start_page, end_page, self.config, cache_index)
        totals.total = totals.total + summary.total
        totals.complete = totals.complete + summary.complete
        totals.skipped = totals.skipped + summary.skipped
        totals.partial = totals.partial + summary.partial
        totals.missing = totals.missing + summary.missing
        totals.bytes = totals.bytes + summary.bytes
        local stats = {
            T(_("%1/%2 hazir"), tostring(summary.ready or 0), tostring(summary.total or 0)),
            T(_("%1 eksik"), tostring(summary.missing or 0)),
        }
        if (tonumber(summary.partial) or 0) > 0 then
            stats[#stats + 1] = T(_("%1 kismi"), tostring(summary.partial))
        end
        if (tonumber(summary.skipped) or 0) > 0 then
            stats[#stats + 1] = T(_("%1 metinsiz"), tostring(summary.skipped))
        end
        items[#items + 1] = {
            text = T(_("Bolum %1  S. %2-%3\n%4"),
                tostring(part),
                tostring(start_page),
                tostring(end_page),
                table.concat(stats, "  ")),
            mandatory = Engine.percentLabel(summary.percent),
            part = part,
            start_page = start_page,
            end_page = end_page,
            summary = summary,
        }
        part = part + 1
    end

    totals.ready = totals.complete + totals.skipped
    totals.remaining = math.max(0, totals.total - totals.ready)
    totals.percent = totals.total > 0 and (totals.ready / totals.total) or 0
    return items, totals
end

function TTSReader:_ttsCacheSubtitle(totals)
    local pct = math.floor((tonumber(totals.percent) or 0) * 100 + 0.5)
    local parts = {
        T(_("%1/%2 sayfa hazir"), tostring(totals.ready or 0), tostring(totals.total or 0)),
        T(_("%1 eksik"), tostring(totals.missing or 0)),
    }
    if (tonumber(totals.partial) or 0) > 0 then
        parts[#parts + 1] = T(_("%1 kismi"), tostring(totals.partial))
    end
    parts[#parts + 1] = self:_formatCacheBytes(totals.bytes)
    return table.concat(parts, "  ")
end

function TTSReader:_refreshTTSCacheMenu(menu, part)
    if not menu then
        return
    end
    self:_refreshConfig()
    local items, totals = self:_buildTTSCachePartItems()
    menu:switchItemTable(_("TTS onbellegi"), items, nil, part and { part = part } or nil, self:_ttsCacheSubtitle(totals))
end

function TTSReader:_startCacheGeneration(start_page, end_page, mode, label, menu)
    if menu then
        UIManager:close(menu)
        if self.tts_cache_menu == menu then
            self.tts_cache_menu = nil
        end
    end
    self:startGeneration{
        start_page = start_page,
        end_page = end_page,
        mode = mode,
        label = label,
    }
end

function TTSReader:_confirmCacheRedownload(start_page, end_page, label, menu)
    UIManager:show(ConfirmBox:new{
        text = T(_("Sayfa %1-%2 sesini bastan indir?\nBu araliktaki mevcut ses degistirilecek."),
            tostring(start_page),
            tostring(end_page)),
        ok_text = _("Bastan indir"),
        ok_callback = function()
            self:_startCacheGeneration(start_page, end_page, "redownload", label, menu)
        end,
    })
end

function TTSReader:_showTTSCachePageActions(page_menu, page_item, parent_menu)
    local page = page_item.page
    local state = page_item.status.state
    local can_download = state == "missing" or state == "partial"
    local download_text = state == "partial" and _("Eksikleri indir") or _("Indir")
    if state == "complete" then
        download_text = _("Hazir")
    elseif state == "skipped" then
        download_text = _("Metin yok")
    end
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Sayfa %1\n%2"),
            tostring(page),
            self:_pageCacheDetailText(page_item.status)),
        width = math.floor(Screen:getWidth() * 0.92),
        buttons = {
            {
                {
                    text = download_text,
                    enabled = can_download,
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:close(page_menu)
                        if parent_menu then
                            UIManager:close(parent_menu)
                            if self.tts_cache_menu == parent_menu then
                                self.tts_cache_menu = nil
                            end
                        end
                        self:startGeneration{
                            start_page = page,
                            end_page = page,
                            mode = "missing",
                            label = T(_("Sayfa %1"), tostring(page)),
                        }
                    end,
                },
                {
                    text = _("Bastan indir"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:close(page_menu)
                        self:_confirmCacheRedownload(page, page, T(_("Sayfa %1"), tostring(page)), parent_menu)
                    end,
                },
            },
            {
                {
                    text = _("Sayfaya git"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:close(page_menu)
                        if parent_menu then
                            UIManager:close(parent_menu)
                            if self.tts_cache_menu == parent_menu then
                                self.tts_cache_menu = nil
                            end
                        end
                        self.ui:handleEvent(Event:new("GotoPage", page))
                    end,
                },
                {
                    text = _("Kapat"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function TTSReader:_showTTSCachePageList(part_item, parent_menu)
    local summary = Engine.rangeCacheStatus(self:_bookDir(), part_item.start_page, part_item.end_page, self.config)
    local pages = {}
    for status_index, status in ipairs(summary.pages) do
        pages[status_index] = status
    end
    table.sort(pages, function(a, b)
        local rank_a = Engine.cacheStateSortRank(a.state)
        local rank_b = Engine.cacheStateSortRank(b.state)
        if rank_a == rank_b then
            return (tonumber(a.page) or 0) < (tonumber(b.page) or 0)
        end
        return rank_a < rank_b
    end)
    local items = {}
    for status_index, status in ipairs(pages) do
        local text = T(_("Sayfa %1"), tostring(status.page))
        if status.state ~= "missing" and status.state ~= "skipped" then
            text = T(_("Sayfa %1\n%2/%3 parca  %4"),
                tostring(status.page),
                tostring(status.audio_count or 0),
                tostring(status.segment_count or 0),
                self:_formatCacheBytes(status.bytes))
        end
        items[#items + 1] = {
            text = text,
            mandatory = self:_cacheStateLabel(status.state),
            page = status.page,
            status = status,
        }
    end

    local page_menu
    page_menu = Menu:new{
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title = T(_("Bolum %1 sayfalari"), tostring(part_item.part)),
        subtitle = T(_("Sayfa %1-%2  %3"), tostring(part_item.start_page), tostring(part_item.end_page), self:_partCacheSummaryText(summary)),
        item_table = items,
        items_per_page = 8,
        items_max_lines = 2,
        onMenuSelect = function(_, item)
            self:_showTTSCachePageActions(page_menu, item, parent_menu)
        end,
    }
    UIManager:show(page_menu)
end

function TTSReader:_showTTSCachePartActions(menu, item)
    if not item or not item.summary then
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Bolum %1  sayfa %2-%3\n%4"),
            tostring(item.part),
            tostring(item.start_page),
            tostring(item.end_page),
            self:_partCacheSummaryText(item.summary)),
        width = math.floor(Screen:getWidth() * 0.92),
        buttons = {
            {
                {
                    text = _("Eksikleri indir"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_startCacheGeneration(
                            item.start_page,
                            item.end_page,
                            "missing",
                            T(_("Bolum %1 eksikleri"), tostring(item.part)),
                            menu
                        )
                    end,
                },
                {
                    text = _("Bastan indir"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_confirmCacheRedownload(
                            item.start_page,
                            item.end_page,
                            T(_("Bolum %1 bastan"), tostring(item.part)),
                            menu
                        )
                    end,
                },
            },
            {
                {
                    text = _("Sayfalari goster"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_showTTSCachePageList(item, menu)
                    end,
                },
                {
                    text = _("Yenile"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_refreshTTSCacheMenu(menu, item.part)
                    end,
                },
            },
            {
                {
                    text = _("Kapat"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function TTSReader:showTTSCacheManager()
    if not self:_hasDocument() then
        self:_show(_("Open a book first."))
        return
    end
    if not self:_narrationVoice() then
        self:chooseNarrationLanguage(function()
            self:showTTSCacheManager()
        end)
        return
    end
    self:_refreshConfig()
    local items, totals = self:_buildTTSCachePartItems()
    local menu
    menu = Menu:new{
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        title = _("TTS onbellegi"),
        subtitle = self:_ttsCacheSubtitle(totals),
        item_table = items,
        items_per_page = 8,
        items_max_lines = 2,
        onMenuSelect = function(_, item)
            self:_showTTSCachePartActions(menu, item)
        end,
        onLeftButtonTap = function()
            self:_refreshTTSCacheMenu(menu)
        end,
        close_callback = function()
            if self.tts_cache_menu == menu then
                self.tts_cache_menu = nil
            end
        end,
    }
    self.tts_cache_menu = menu
    UIManager:show(menu)
end

function TTSReader:showStatus()
    self:_refreshConfig()
    local narration_config = self:_narrationConfig()
    local lines = {
        _("Sesli okuma"),
        T(_("Google anahtari: %1"), Engine.maskSecret(self.config.api_key)),
        T(_("Dil: %1"), self:_narrationLanguageLabel()),
        T(_("Ses: %1"), narration_config.voice_name),
        T(_("Oynatma hizi: %1"), Engine.speedLabel(self.config.playback_speed)),
        T(_("Parca boyutu: %1 sayfa"), tostring(self.config.page_chunk_size)),
        T(_("Onbellek: %1"), Engine.cache_dir),
    }
    if Engine.hasBluetoothAudio(self.config) then
        lines[#lines + 1] = T(_("Bluetooth kulaklik: %1"), Engine.bluetoothMac(self.config.bluetooth_mac))
    end
    if self.generation and self.generation.active then
        lines[#lines + 1] = T(_("Sayfa hazirlaniyor: %1/%2"), tostring(self.generation.next_page), tostring(self.generation.end_page))
    end
    if self.playback and self.playback.active then
        local current_line = self:_currentPlaybackLine()
        if current_line then
            lines[#lines + 1] = T(_("Ses sayfasi %1, satir %2"), tostring(self.playback.page), tostring(current_line))
        else
            lines[#lines + 1] = T(_("Ses sayfasi %1"), tostring(self.playback.page))
        end
        if self.playback.bluetooth_status then
            lines[#lines + 1] = T(_("Kulaklik: %1"), Engine.bluetoothStatusLabel(self.playback.bluetooth_status))
        end
    end
    self:_show(table.concat(lines, "\n"), 10)
end

function TTSReader:addToMainMenu(menu_items)
    menu_items.ttsreader = {
        text = _("Sesli okuma"),
        sorting_hint = "main",
        sub_item_table = {
            {
                text = _("Google API anahtari gir"),
                keep_menu_open = true,
                callback = function()
                    self:startKeyServer()
                end,
            },
            {
                text_func = function()
                    return T(_("Seslendirme dili: %1"), self:_narrationLanguageLabel())
                end,
                enabled_func = function()
                    return self:_hasDocument()
                end,
                sub_item_table_func = function()
                    return {
                        {
                            text = _("Turkce"),
                            radio = true,
                            checked_func = function()
                                local selected = self:_narrationVoice()
                                return selected and selected.id == "tr"
                            end,
                            callback = function(touchmenu_instance)
                                self:_setNarrationVoice("tr")
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                            end,
                        },
                        {
                            text = _("English"),
                            radio = true,
                            checked_func = function()
                                local selected = self:_narrationVoice()
                                return selected and selected.id == "en"
                            end,
                            callback = function(touchmenu_instance)
                                self:_setNarrationVoice("en")
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                            end,
                        },
                    }
                end,
            },
            {
                text_func = function()
                    self:_refreshConfig()
                    local pages = tonumber(self.config.page_chunk_size) or Engine.defaults.page_chunk_size
                    return T(_("Sonraki %1 sayfayi hazirla"), tostring(pages))
                end,
                enabled_func = function()
                    return self:_hasDocument()
                end,
                callback = function()
                    self:startGeneration()
                end,
            },
            {
                text = _("Tum kitabi hazirla"),
                enabled_func = function()
                    return self:_hasDocument()
                end,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Kitabin tamamini seslendirmek Google TTS kotasi kullanir. Devam edilsin mi?"),
                        ok_text = _("Hazirla"),
                        ok_callback = function()
                            self:startGeneration{
                                start_page = 1,
                                end_page = self:_pageCount(),
                                label = _("Tum kitap"),
                            }
                        end,
                    })
                end,
            },
            {
                text = _("TTS onbellegi"),
                enabled_func = function()
                    return self:_hasDocument()
                end,
                keep_menu_open = true,
                callback = function()
                    self:showTTSCacheManager()
                end,
            },
            {
                text = _("Bluetooth kulaklik"),
                sub_item_table_func = function()
                    return self:_bluetoothMenuItems()
                end,
            },
            {
                text = _("Oynaticiyi ac"),
                enabled_func = function()
                    return self:_hasDocument()
                end,
                callback = function()
                    self:startPlayback("resume")
                end,
            },
            {
                text = _("Bu sayfadan dinle"),
                enabled_func = function()
                    return self:_hasDocument()
                end,
                callback = function()
                    self.resume_playback = nil
                    self:startPlayback("current")
                end,
            },
            {
                text = _("Ses sayfasina git"),
                enabled_func = function()
                    return self.playback ~= nil or self.resume_playback ~= nil
                end,
                keep_menu_open = true,
                callback = function()
                    self:goToPlaybackPage()
                end,
            },
            {
                text = _("Sesi durdur"),
                enabled_func = function()
                    return self.playback ~= nil or self.generation ~= nil
                end,
                keep_menu_open = true,
                callback = function()
                    self:stopPlayback()
                    self:stopGeneration()
                end,
            },
            {
                text = _("Durum"),
                keep_menu_open = true,
                callback = function()
                    self:showStatus()
                end,
            },
        },
    }
end

return TTSReader
