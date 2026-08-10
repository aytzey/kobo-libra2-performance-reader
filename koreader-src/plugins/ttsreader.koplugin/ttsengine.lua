local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local sha2 = require("ffi/sha2")
local util = require("util")

local Engine = {
    settings_file = DataStorage:getSettingsDir() .. "/ttsreader.lua",
    cache_dir = DataStorage:getDataDir() .. "/tts-cache",
    defaults = {
        api_key = "",
        language_code = "tr-TR",
        voice_name = "tr-TR-Wavenet-E",
        audio_encoding = "MP3",
        sample_rate_hz = 22050,
        speaking_rate = 1.0,
        pitch = 0,
        volume_gain_db = 0,
        page_chunk_size = 200,
        request_char_limit = 4200,
        line_timepoints = true,
        playback_speed = 1.0,
        playback_volume = 1.0,
        player_cmd = "",
        bluetooth_mac = "",
        bluetooth_connect_cmd = "",
        bluetooth_warmup_seconds = 1.2,
        bluetooth_idle_refresh_seconds = 45,
        bluetooth_retry_limit = 2,
    },
    narration_voices = {
        tr = {
            language_code = "tr-TR",
            voice_name = "tr-TR-Wavenet-E",
        },
        en = {
            language_code = "en-US",
            voice_name = "en-US-Wavenet-D",
        },
    },
    playback_speeds = { 0.75, 1.0, 1.2, 1.5, 2.0 },
    playback_volumes = { 0.5, 0.65, 0.8, 1.0, 1.2, 1.5 },
}

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local function fileSize(path)
    return tonumber(lfs.attributes(path, "size")) or 0
end

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

function Engine.ensureDir(path)
    if not exists(path) then
        util.makePath(path)
    end
end

function Engine.normalizeAudioEncoding(encoding)
    local clean = tostring(encoding or ""):upper():gsub("%s+", "")
    if clean == "MP3" then
        return "MP3"
    end
    if clean == "LINEAR16" then
        return "LINEAR16"
    end
    return Engine.defaults.audio_encoding
end

function Engine.openSettings()
    local settings = LuaSettings:open(Engine.settings_file)
    if type(settings.data) ~= "table" then
        settings.data = {}
    end
    if type(settings.data.google_tts) ~= "table" then
        settings.data.google_tts = {}
    end
    return settings
end

function Engine.readConfig(settings)
    local saved = (settings and settings.data and settings.data.google_tts) or {}
    local cfg = {}
    for key, value in pairs(Engine.defaults) do
        if saved[key] == nil then
            cfg[key] = value
        else
            cfg[key] = saved[key]
        end
    end
    cfg.audio_encoding = Engine.defaults.audio_encoding
    cfg.playback_speed = Engine.normalizePlaybackSpeed(cfg.playback_speed)
    cfg.playback_volume = Engine.normalizePlaybackVolume(cfg.playback_volume)
    cfg.sample_rate_hz = tonumber(cfg.sample_rate_hz) or Engine.defaults.sample_rate_hz
    return cfg
end

function Engine.narrationVoice(id)
    local voice = Engine.narration_voices[id]
    if not voice then
        return nil
    end
    return {
        id = id,
        language_code = voice.language_code,
        voice_name = voice.voice_name,
    }
end

function Engine.narrationVoiceCacheKey(voice)
    if type(voice) ~= "table" then
        return nil
    end
    local language_code = tostring(voice.language_code or "")
    local voice_name = tostring(voice.voice_name or "")
    if language_code == "" or voice_name == "" then
        return nil
    end
    return language_code .. "\n" .. voice_name
end

function Engine.saveConfig(settings, cfg)
    local clean = {}
    for key, value in pairs(Engine.defaults) do
        clean[key] = cfg[key] == nil and value or cfg[key]
    end
    clean.audio_encoding = Engine.defaults.audio_encoding
    clean.playback_speed = Engine.normalizePlaybackSpeed(clean.playback_speed)
    clean.playback_volume = Engine.normalizePlaybackVolume(clean.playback_volume)
    clean.sample_rate_hz = tonumber(clean.sample_rate_hz) or Engine.defaults.sample_rate_hz
    settings:saveSetting("google_tts", clean)
    settings:flush()
end

function Engine.maskSecret(value)
    if type(value) ~= "string" or value == "" then
        return "not set"
    end
    if #value <= 8 then
        return "set"
    end
    return value:sub(1, 4) .. "..." .. value:sub(-4)
end

function Engine.shellQuote(value)
    return "'" .. tostring(value):gsub("'", [['"'"']]) .. "'"
end

function Engine.formatPlaybackNumber(value)
    local text = string.format("%.3f", tonumber(value) or 0):gsub("0+$", ""):gsub("%.$", "")
    return text == "" and "0" or text
end

function Engine.speedLabel(speed)
    return Engine.formatPlaybackNumber(speed) .. "x"
end

function Engine.volumeLabel(volume)
    return tostring(math.floor(Engine.normalizePlaybackVolume(volume) * 100 + 0.5)) .. "%"
end

function Engine.percentLabel(ratio)
    return tostring(math.floor((tonumber(ratio) or 0) * 100 + 0.5)) .. "%"
end

function Engine.cacheStateSortRank(state)
    if state == "missing" then
        return 1
    elseif state == "partial" then
        return 2
    elseif state == "skipped" then
        return 3
    elseif state == "complete" then
        return 4
    end
    return 5
end

function Engine.normalizePlaybackSpeed(speed)
    speed = tonumber(speed) or Engine.defaults.playback_speed
    local best = Engine.playback_speeds[1]
    local best_delta = math.huge
    for _, candidate in ipairs(Engine.playback_speeds) do
        local delta = math.abs(speed - candidate)
        if delta < best_delta then
            best = candidate
            best_delta = delta
        end
    end
    return best
end

function Engine.nextPlaybackSpeed(speed)
    speed = Engine.normalizePlaybackSpeed(speed)
    for i, candidate in ipairs(Engine.playback_speeds) do
        if candidate == speed then
            return Engine.playback_speeds[(i % #Engine.playback_speeds) + 1]
        end
    end
    return Engine.defaults.playback_speed
end

function Engine.normalizePlaybackVolume(volume)
    volume = tonumber(volume) or Engine.defaults.playback_volume
    local best = Engine.playback_volumes[1]
    local best_delta = math.huge
    for _, candidate in ipairs(Engine.playback_volumes) do
        local delta = math.abs(volume - candidate)
        if delta < best_delta then
            best = candidate
            best_delta = delta
        end
    end
    return best
end

function Engine.adjustPlaybackVolume(volume, direction)
    volume = Engine.normalizePlaybackVolume(volume)
    direction = tonumber(direction) or 1
    for i, candidate in ipairs(Engine.playback_volumes) do
        if candidate == volume then
            return Engine.playback_volumes[clamp(i + (direction < 0 and -1 or 1), 1, #Engine.playback_volumes)]
        end
    end
    return Engine.defaults.playback_volume
end

function Engine.playbackPageDrift(current_page, audio_page)
    current_page = math.floor(tonumber(current_page) or 0)
    audio_page = math.floor(tonumber(audio_page) or 0)
    if current_page < 1 or audio_page < 1 or current_page == audio_page then
        return nil
    end
    return {
        current_page = current_page,
        audio_page = audio_page,
        delta = current_page - audio_page,
    }
end

function Engine.playerName(player)
    local command = tostring(player or ""):match("^%s*(%S+)") or ""
    return command:match("([^/]+)$") or command
end

function Engine.isNativePlayer(player)
    return Engine.playerName(player) == "ttsreader-play"
end

function Engine.bluetoothMac(value)
    local clean = util.trim(tostring(value or "")):upper()
    if clean:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        return clean
    end
    return ""
end

function Engine.hasBluetoothAudio(cfg)
    return Engine.bluetoothMac(cfg and cfg.bluetooth_mac) ~= ""
end

function Engine.bluetoothAudioDevice(mac)
    local clean = Engine.bluetoothMac(mac)
    if clean ~= "" then
        return "bluealsa:DEV=" .. clean .. ",PROFILE=a2dp"
    end
    return "default"
end

function Engine.bluetoothInfoConnected(output)
    return tostring(output or ""):match("Connected:%s*yes") ~= nil
end

function Engine.bluetoothConnectFailureStatus(output, status, timeout_marker, stack_failed_marker)
    local text = tostring(output or "")
    local lower_text = text:lower()
    local numeric_status = tonumber(status)

    if stack_failed_marker and text:find(stack_failed_marker, 1, true) then
        return "bt stack failed"
    end
    if (timeout_marker and text:find(timeout_marker, 1, true)) or numeric_status == 124 then
        return "connect timeout"
    end
    if lower_text:find("br%-connection%-page%-timeout")
        or lower_text:find("page timeout", 1, true)
        or lower_text:find("host is down", 1, true)
        or lower_text:find("device not available", 1, true)
    then
        return "not reachable"
    end
    if lower_text:find("authentication", 1, true)
        or lower_text:find("not paired", 1, true)
        or lower_text:find("not authorized", 1, true)
    then
        return "pairing issue"
    end
    return "connect failed"
end

function Engine.bluetoothStatusLabel(status)
    local text = tostring(status or "")
    local exact = {
        ["ready"] = "hazir",
        ["not connected"] = "bagli degil",
        ["connecting"] = "baglaniyor",
        ["refreshing"] = "yenileniyor",
        ["streaming"] = "caliyor",
        ["starting audio"] = "ses basliyor",
        ["checking"] = "kontrol",
        ["connection lost"] = "baglanti koptu",
        ["connect failed"] = "baglanti yok",
        ["connect timeout"] = "sure asimi",
        ["reconnect failed"] = "baglanamadi",
        ["not reachable"] = "bulunamadi",
        ["pairing issue"] = "eslesme hatasi",
        ["bt stack failed"] = "bt baslamadi",
    }
    if exact[text] then
        return exact[text]
    end

    local retry = text:match("^reconnecting%s+(.+)$")
    if retry then
        return "yeniden baglaniyor " .. retry
    end
    return text
end

function Engine.bluetoothHeaderLabel(status)
    local label = Engine.bluetoothStatusLabel(status)
    if label == "" then
        return ""
    end
    return "Kulaklik " .. label
end

function Engine.bluetoothConnectScript(mac, force_refresh)
    local clean = Engine.bluetoothMac(mac)
    if clean == "" then
        return nil
    end

    local quoted = Engine.shellQuote(clean)
    local steps = {
        "ensure_bluealsa || exit 1",
    }

    if force_refresh then
        steps[#steps + 1] = "bt 5 disconnect " .. quoted .. " >/tmp/ttsreader-bluetooth-refresh.log 2>&1 || true"
        steps[#steps + 1] = "sleep 0.2"
    else
        steps[#steps + 1] = "bt_info=\"$(bt 3 info " .. quoted .. " 2>/dev/null || true)\""
        steps[#steps + 1] = "if printf '%s\\n' \"$bt_info\" | grep -q 'Connected: yes'; then"
        steps[#steps + 1] = "    echo ::INFO::"
        steps[#steps + 1] = "    printf '%s\\n' \"$bt_info\""
        steps[#steps + 1] = "    exit 0"
        steps[#steps + 1] = "fi"
    end

    steps[#steps + 1] = "bt 9 connect " .. quoted
    steps[#steps + 1] = "connect_rc=$?"
    steps[#steps + 1] = "if [ \"$connect_rc\" -ne 0 ]; then"
    steps[#steps + 1] = "    bt 2 scan on >>/tmp/ttsreader-bluetooth-wakeup.log 2>&1 || true"
    steps[#steps + 1] = "    sleep 0.8"
    steps[#steps + 1] = "    bt_scan_off_quiet >>/tmp/ttsreader-bluetooth-wakeup.log 2>&1 || true"
    steps[#steps + 1] = "    bt 9 connect " .. quoted
    steps[#steps + 1] = "    connect_rc=$?"
    steps[#steps + 1] = "fi"
    steps[#steps + 1] = "echo ::INFO::"
    steps[#steps + 1] = "bt 4 info " .. quoted .. " 2>/dev/null || true"
    steps[#steps + 1] = "exit \"$connect_rc\""

    return table.concat(steps, "\n")
end

function Engine.bluetoothPowerOffScript()
    return table.concat({
        "if ! hciconfig hci0 >/dev/null 2>&1 && ! pgrep bluealsa >/dev/null 2>&1 && ! grep -q '^sdio_bt_pwr ' /proc/modules 2>/dev/null; then exit 0; fi",
        "hciconfig hci0 down >/dev/null 2>&1 || true",
        "killall -q -TERM bluealsa bluetoothd rtk_hciattach 2>/dev/null || true",
        "sleep 0.2",
        "rmmod sdio_bt_pwr >/dev/null 2>&1 || true",
    }, "\n")
end

function Engine.bluetoothConnectTimeoutSeconds(warmup_seconds)
    local warmup = tonumber(warmup_seconds) or Engine.defaults.bluetooth_warmup_seconds
    warmup = clamp(warmup, 0.6, 3.0)
    return math.max(24, math.floor(warmup + 18))
end

function Engine.bluetoothReadyGateSeconds(warmup_seconds)
    return Engine.bluetoothConnectTimeoutSeconds(warmup_seconds) + 4
end

function Engine.bluetoothInputNameMatches(name)
    local lower_name = tostring(name or ""):lower()
    return lower_name:find("avrcp", 1, true) ~= nil
        or lower_name:find("remote control", 1, true) ~= nil
        or lower_name:find("bluetooth", 1, true) ~= nil
        or lower_name:find("headphone", 1, true) ~= nil
        or lower_name:find("headset", 1, true) ~= nil
        or lower_name:find("earbud", 1, true) ~= nil
        or lower_name:find("sony", 1, true) ~= nil
        or lower_name:find("wh-", 1, true) ~= nil
        or lower_name:find("wf-", 1, true) ~= nil
        or lower_name:find("xm", 1, true) ~= nil
end

function Engine.bluetoothInputDevicesFromProc(content)
    local devices = {}
    for block in (tostring(content or "") .. "\n\n"):gmatch("(.-)\n\n") do
        local name = block:match('N:%s+Name="([^"]+)"')
        local handlers = block:match("H:%s+Handlers=([^\n]+)") or ""
        local event = handlers:match("(%f[%w]event%d+%f[%W])")
        if name and event then
            local bus = block:match("I:%s+Bus=([0-9A-Fa-f]+)")
            local lower_name = name:lower()
            local excluded_input = lower_name:find("keyboard", 1, true) ~= nil
                or lower_name:find("mouse", 1, true) ~= nil
            local is_bluetooth_media_input = bus == "0005"
                and handlers:find("kbd", 1, true) ~= nil
                and not excluded_input
            if not excluded_input and (Engine.bluetoothInputNameMatches(name) or is_bluetooth_media_input) then
                devices[#devices + 1] = {
                    name = name,
                    path = "/dev/input/" .. event,
                }
            end
        end
    end
    return devices
end

function Engine.bluetoothInputDevicePathsFromProc(content)
    local paths = {}
    for _, device in ipairs(Engine.bluetoothInputDevicesFromProc(content)) do
        paths[device.path] = device.name
    end
    return paths
end

function Engine.parseBluetoothDevices(output)
    local devices = {}
    local by_mac = {}
    local paired_section = false
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        if line == "::PAIRED::" then
            paired_section = true
        else
            local clean = line:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
            local mac, name = clean:match("Device%s+([%x:]+)%s*(.-)%s*$")
            mac = Engine.bluetoothMac(mac)
            if mac ~= "" then
                local device = by_mac[mac]
                if not device then
                    device = {
                        mac = mac,
                        name = name ~= "" and name or mac,
                        paired = false,
                    }
                    by_mac[mac] = device
                    devices[#devices + 1] = device
                elseif name ~= "" and device.name == mac then
                    device.name = name
                end
                if paired_section then
                    device.paired = true
                end
            end
        end
    end
    table.sort(devices, function(a, b)
        if a.paired ~= b.paired then
            return a.paired
        end
        return (a.name or a.mac):lower() < (b.name or b.mac):lower()
    end)
    return devices
end

function Engine.playerCommand(player, path, speed, seek_seconds, device, volume, volume_control_path)
    speed = Engine.normalizePlaybackSpeed(speed)
    seek_seconds = math.max(0, tonumber(seek_seconds) or 0)
    volume = Engine.normalizePlaybackVolume(volume)

    local quoted = Engine.shellQuote(path)
    local quoted_device = Engine.shellQuote(device or "default")
    local quoted_volume_control = volume_control_path and Engine.shellQuote(volume_control_path) or nil
    local speed_arg = Engine.formatPlaybackNumber(speed)
    local seek_arg = Engine.formatPlaybackNumber(seek_seconds)
    local volume_arg = Engine.formatPlaybackNumber(volume)
    local info = {
        speed = speed,
        effective_speed = speed,
        speed_supported = speed == 1.0,
        seek_supported = seek_seconds == 0,
        volume = volume,
        effective_volume = volume,
        volume_supported = volume == 1.0,
        live_volume_supported = false,
    }

    if player:find("{file}", 1, true) then
        local command = player
            :gsub("{file}", function()
                return quoted
            end)
            :gsub("{speed}", function()
                info.speed_supported = true
                return speed_arg
            end)
            :gsub("{seek}", function()
                info.seek_supported = true
                return seek_arg
            end)
            :gsub("{volume}", function()
                info.volume_supported = true
                return volume_arg
            end)
            :gsub("{device}", function()
                return quoted_device
            end)
        if not info.speed_supported then
            info.effective_speed = 1.0
        end
        if not info.volume_supported then
            info.effective_volume = 1.0
        end
        return command, info
    end

    local executable = tostring(player or ""):match("^%s*(%S+)") or tostring(player or "")
    local name = Engine.playerName(player)
    local base = Engine.shellQuote(executable)
    if Engine.isNativePlayer(player) then
        info.speed_supported = true
        info.seek_supported = true
        info.volume_supported = true
        info.live_volume_supported = quoted_volume_control ~= nil
        local seek = seek_seconds > 0 and (" --seek " .. seek_arg) or ""
        local volume_control = quoted_volume_control and (" --volume-control " .. quoted_volume_control) or ""
        return base .. " --quiet --device " .. quoted_device .. " --speed " .. speed_arg .. " --volume " .. volume_arg .. volume_control .. seek .. " " .. quoted, info
    elseif name == "mpv" then
        info.speed_supported = true
        info.seek_supported = true
        info.volume_supported = true
        local seek = seek_seconds > 0 and (" --start=" .. seek_arg) or ""
        return base .. " --no-video --really-quiet --speed=" .. speed_arg .. " --volume=" .. tostring(math.floor(volume * 100 + 0.5)) .. seek .. " " .. quoted, info
    elseif name == "mplayer" then
        info.speed_supported = true
        info.seek_supported = true
        info.volume_supported = true
        local seek = seek_seconds > 0 and (" -ss " .. seek_arg) or ""
        return base .. " -really-quiet -speed " .. speed_arg .. " -volume " .. tostring(math.floor(volume * 100 + 0.5)) .. seek .. " " .. quoted, info
    elseif name == "ffplay" then
        info.speed_supported = true
        info.seek_supported = true
        info.volume_supported = true
        local seek = seek_seconds > 0 and (" -ss " .. seek_arg) or ""
        return base .. " -nodisp -autoexit -loglevel quiet -af atempo=" .. speed_arg .. " -volume " .. tostring(math.floor(volume * 100 + 0.5)) .. seek .. " " .. quoted, info
    elseif name == "mpg123" then
        info.effective_speed = 1.0
        info.effective_volume = 1.0
        return base .. " -q " .. quoted, info
    elseif name == "madplay" then
        info.effective_speed = 1.0
        info.effective_volume = 1.0
        return base .. " -q " .. quoted, info
    end

    info.effective_speed = 1.0
    info.effective_volume = 1.0
    return base .. " " .. quoted, info
end

function Engine.bookId(path, title, variant)
    local identity = (path or "") .. "\n" .. (title or "")
    if variant and variant ~= "" then
        identity = identity .. "\n" .. variant
    end
    return sha2.sha1(identity):sub(1, 20)
end

function Engine.bookCacheDir(path, title, variant)
    local dir = Engine.cache_dir .. "/" .. Engine.bookId(path, title, variant)
    Engine.ensureDir(dir)
    return dir
end

function Engine.segmentExtensionForEncoding(encoding)
    return Engine.normalizeAudioEncoding(encoding) == "LINEAR16" and "wav" or "mp3"
end

function Engine.segmentPathForEncoding(book_dir, page, segment, encoding)
    return string.format(
        "%s/p%06d-s%02d.%s",
        book_dir,
        page,
        segment,
        Engine.segmentExtensionForEncoding(encoding)
    )
end

function Engine.segmentPath(book_dir, page, segment, cfg)
    local encoding = type(cfg) == "table" and cfg.audio_encoding or cfg
    return Engine.segmentPathForEncoding(book_dir, page, segment, encoding or Engine.defaults.audio_encoding)
end

function Engine.segmentCandidatePaths(book_dir, page, segment, cfg)
    local preferred_encoding = type(cfg) == "table" and cfg.audio_encoding or cfg
    preferred_encoding = Engine.normalizeAudioEncoding(preferred_encoding or Engine.defaults.audio_encoding)
    local preferred = Engine.segmentPathForEncoding(book_dir, page, segment, preferred_encoding)
    local candidates = { preferred }
    local fallback = preferred_encoding == "LINEAR16" and "MP3" or "LINEAR16"
    local fallback_path = Engine.segmentPathForEncoding(book_dir, page, segment, fallback)
    if fallback_path ~= preferred then
        candidates[#candidates + 1] = fallback_path
    end
    return candidates
end

function Engine.existingSegmentPath(book_dir, page, segment, cfg)
    for _, path in ipairs(Engine.segmentCandidatePaths(book_dir, page, segment, cfg)) do
        if exists(path) then
            return path
        end
    end
end

function Engine.segmentMetaPath(book_dir, page, segment)
    return string.format("%s/p%06d-s%02d.json", book_dir, page, segment)
end

function Engine.pageLinesPath(book_dir, page)
    return string.format("%s/p%06d.lines", book_dir, page)
end

function Engine.donePath(book_dir, page)
    return string.format("%s/p%06d.done", book_dir, page)
end

function Engine.skipPath(book_dir, page)
    return string.format("%s/p%06d.skip", book_dir, page)
end

local function readDoneCountPath(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local count = tonumber(file:read("*l"))
    file:close()
    return count
end

function Engine.readDoneCount(book_dir, page)
    return readDoneCountPath(Engine.donePath(book_dir, page))
end

function Engine.pageCacheStatus(book_dir, page, cfg)
    page = math.floor(tonumber(page) or 0)
    local done_count = Engine.readDoneCount(book_dir, page)
    local skipped = exists(Engine.skipPath(book_dir, page))
    local status = {
        page = page,
        state = "missing",
        done_count = done_count or 0,
        segment_count = 0,
        audio_count = 0,
        meta_count = 0,
        bytes = 0,
        has_lines = exists(Engine.pageLinesPath(book_dir, page)),
        has_done = done_count ~= nil,
        skipped = skipped,
    }

    if skipped and not done_count then
        status.state = "skipped"
        return status
    end

    if not done_count or done_count < 1 then
        return status
    end

    status.segment_count = done_count
    for i = 1, done_count do
        local audio_path = Engine.existingSegmentPath(book_dir, page, i, cfg)
        if audio_path then
            status.audio_count = status.audio_count + 1
            status.bytes = status.bytes + fileSize(audio_path)
        end
        if Engine.readSegmentMeta(book_dir, page, i) then
            status.meta_count = status.meta_count + 1
        end
    end

    if status.audio_count == done_count and status.meta_count == done_count then
        status.state = "complete"
    elseif status.audio_count > 0 or status.meta_count > 0 or status.has_lines or done_count then
        status.state = "partial"
    end
    return status
end

function Engine.isPageComplete(book_dir, page, cfg)
    local status = Engine.pageCacheStatus(book_dir, page, cfg)
    return status.state == "complete" or status.state == "skipped"
end

function Engine.generatedSegments(book_dir, page, cfg)
    local count = Engine.readDoneCount(book_dir, page)
    if not count or count < 1 then
        return nil
    end
    local segments = {}
    for i = 1, count do
        local path = Engine.existingSegmentPath(book_dir, page, i, cfg)
        if not path then
            return nil
        end
        segments[#segments + 1] = path
    end
    return segments
end

function Engine.readSegmentMeta(book_dir, page, segment)
    local file = io.open(Engine.segmentMetaPath(book_dir, page, segment), "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    local ok, decoded = pcall(rapidjson.decode, content)
    if ok and type(decoded) == "table" then
        return decoded
    end
end

function Engine.writeSegmentMeta(book_dir, page, segment, meta)
    local path = Engine.segmentMetaPath(book_dir, page, segment)
    local tmp = path .. ".tmp"
    local file = assert(io.open(tmp, "w"))
    file:write(rapidjson.encode(meta or {}))
    file:write("\n")
    file:close()
    os.rename(tmp, path)
end

local function cacheIndexCovers(cache_index, book_dir, start_page, end_page)
    return type(cache_index) == "table"
        and cache_index.book_dir == book_dir
        and (tonumber(cache_index.start_page) or 0) <= start_page
        and (tonumber(cache_index.end_page) or 0) >= end_page
end

local function cacheAudioExts(cfg)
    local preferred_encoding = type(cfg) == "table" and cfg.audio_encoding or cfg
    preferred_encoding = Engine.normalizeAudioEncoding(preferred_encoding or Engine.defaults.audio_encoding)
    local preferred_ext = Engine.segmentExtensionForEncoding(preferred_encoding)
    return preferred_ext, preferred_ext == "wav" and "mp3" or "wav"
end

local function pageCacheStatusFromIndexedPage(book_dir, page, cached, preferred_ext, fallback_ext)
    cached = cached or {}
    local done_count = cached.done_path and readDoneCountPath(cached.done_path) or nil
    local status = {
        page = page,
        state = "missing",
        done_count = done_count or 0,
        segment_count = 0,
        audio_count = 0,
        meta_count = 0,
        bytes = 0,
        has_lines = cached.has_lines == true,
        has_done = done_count ~= nil,
        skipped = cached.skipped == true,
    }

    if status.skipped and not done_count then
        status.state = "skipped"
        return status
    end
    if not done_count or done_count < 1 then
        return status
    end

    status.segment_count = done_count
    for i = 1, done_count do
        local audio_paths = cached.audio and cached.audio[i]
        local audio_path = audio_paths and (audio_paths[preferred_ext] or audio_paths[fallback_ext])
        if audio_path then
            status.audio_count = status.audio_count + 1
            status.bytes = status.bytes + fileSize(audio_path)
        end
        if cached.meta and cached.meta[i] and Engine.readSegmentMeta(book_dir, page, i) then
            status.meta_count = status.meta_count + 1
        end
    end

    if status.audio_count == done_count and status.meta_count == done_count then
        status.state = "complete"
    elseif status.audio_count > 0 or status.meta_count > 0 or status.has_lines or done_count then
        status.state = "partial"
    end
    return status
end

local function generatedSegmentEntriesFromIndexedPage(book_dir, page, cached, preferred_ext, fallback_ext)
    cached = cached or {}
    local done_count = cached.done_path and readDoneCountPath(cached.done_path) or nil
    if not done_count or done_count < 1 then
        return nil
    end

    local entries = {}
    for i = 1, done_count do
        local audio_paths = cached.audio and cached.audio[i]
        local audio_path = audio_paths and (audio_paths[preferred_ext] or audio_paths[fallback_ext])
        if not audio_path then
            return nil
        end
        entries[#entries + 1] = {
            index = i,
            path = audio_path,
            meta = cached.meta and cached.meta[i] and Engine.readSegmentMeta(book_dir, page, i) or nil,
        }
    end
    return entries
end

function Engine.generatedSegmentEntries(book_dir, page, cfg)
    local paths = Engine.generatedSegments(book_dir, page, cfg)
    if not paths then
        return nil
    end
    local entries = {}
    for i, path in ipairs(paths) do
        entries[#entries + 1] = {
            index = i,
            path = path,
            meta = Engine.readSegmentMeta(book_dir, page, i),
        }
    end
    return entries
end

function Engine.nextPlayableSegmentEntries(book_dir, start_page, end_page, cfg, cache_index)
    start_page = math.max(1, math.floor(tonumber(start_page) or 1))
    end_page = math.max(start_page, math.floor(tonumber(end_page) or start_page))
    if not cacheIndexCovers(cache_index, book_dir, start_page, end_page) then
        cache_index = Engine.buildCacheStatusIndex(book_dir, start_page, end_page)
    end
    if cache_index.ok == false then
        cache_index = nil
    end
    local pages_by_number = cache_index and cache_index.pages_by_number
    local preferred_ext, fallback_ext = cacheAudioExts(cfg)
    local skipped = 0
    for page = start_page, end_page do
        local cached = pages_by_number and pages_by_number[page]
        local entries = cache_index
            and generatedSegmentEntriesFromIndexedPage(book_dir, page, cached, preferred_ext, fallback_ext)
            or Engine.generatedSegmentEntries(book_dir, page, cfg)
        if entries then
            return page, entries, skipped, nil
        end
        local status = cache_index
            and pageCacheStatusFromIndexedPage(book_dir, page, cached, preferred_ext, fallback_ext)
            or Engine.pageCacheStatus(book_dir, page, cfg)
        if status.state == "skipped" then
            skipped = skipped + 1
        else
            return nil, nil, skipped, status
        end
    end
    return nil, nil, skipped, {
        page = end_page + 1,
        state = "finished",
    }
end

function Engine.markPageDone(book_dir, page, count)
    local path = Engine.donePath(book_dir, page)
    local tmp = path .. ".tmp"
    local file = assert(io.open(tmp, "w"))
    file:write(tostring(count), "\n")
    file:close()
    os.rename(tmp, path)
end

function Engine.markPageSkipped(book_dir, page, reason)
    local path = Engine.skipPath(book_dir, page)
    local tmp = path .. ".tmp"
    local file = assert(io.open(tmp, "w"))
    file:write(reason or "empty", "\n")
    file:close()
    os.rename(tmp, path)
end

function Engine.clearPageCache(book_dir, page)
    page = math.floor(tonumber(page) or 0)
    if page < 1 then
        return 0
    end

    local prefix = string.format("p%06d", page)
    local removed = 0
    local function removePath(path)
        if exists(path) and os.remove(path) then
            removed = removed + 1
        end
    end

    removePath(Engine.donePath(book_dir, page))
    removePath(Engine.skipPath(book_dir, page))
    removePath(Engine.pageLinesPath(book_dir, page))

    local ok, iter, dir_obj = pcall(lfs.dir, book_dir)
    if not ok or not iter then
        return removed
    end
    for name in iter, dir_obj do
        if name:match("^" .. prefix .. "%-s%d%d%.") then
            removePath(book_dir .. "/" .. name)
        end
    end
    return removed
end

function Engine.clearPageRangeCache(book_dir, start_page, end_page)
    local removed = 0
    start_page = math.floor(tonumber(start_page) or 0)
    end_page = math.floor(tonumber(end_page) or start_page)
    if start_page < 1 or end_page < start_page then
        return 0
    end

    local function removePath(path)
        if exists(path) and os.remove(path) then
            removed = removed + 1
        end
    end

    for page = start_page, end_page do
        removePath(Engine.donePath(book_dir, page))
        removePath(Engine.skipPath(book_dir, page))
        removePath(Engine.pageLinesPath(book_dir, page))
    end

    local ok, iter, dir_obj = pcall(lfs.dir, book_dir)
    if not ok or not iter then
        return removed
    end
    for name in iter, dir_obj do
        local page = tonumber(name:match("^p(%d%d%d%d%d%d)%-s%d%d%."))
        if page and page >= start_page and page <= end_page then
            removePath(book_dir .. "/" .. name)
        end
    end
    return removed
end

function Engine.buildCacheStatusIndex(book_dir, start_page, end_page)
    start_page = math.floor(tonumber(start_page) or 0)
    end_page = math.floor(tonumber(end_page) or start_page)
    local index = {
        book_dir = book_dir,
        start_page = start_page,
        end_page = end_page,
        pages_by_number = {},
        ok = true,
    }

    local ok, iter, dir_obj = pcall(lfs.dir, book_dir)
    if not ok or not iter then
        index.ok = false
        return index
    end

    for name in iter, dir_obj do
        local page_number, suffix = name:match("^p(%d%d%d%d%d%d)(.+)$")
        local page = tonumber(page_number)
        if page and page >= start_page and page <= end_page then
            local cached = index.pages_by_number[page]
            if not cached then
                cached = {
                    audio = {},
                    meta = {},
                }
                index.pages_by_number[page] = cached
            end

            if suffix == ".done" then
                cached.done_path = book_dir .. "/" .. name
            elseif suffix == ".skip" then
                cached.skipped = true
            elseif suffix == ".lines" then
                cached.has_lines = true
            else
                local segment, ext = suffix:match("^%-s(%d%d)%.(.+)$")
                segment = tonumber(segment)
                if segment then
                    if ext == "json" then
                        cached.meta[segment] = true
                    elseif ext == "wav" or ext == "mp3" then
                        local paths = cached.audio[segment]
                        if not paths then
                            paths = {}
                            cached.audio[segment] = paths
                        end
                        paths[ext] = book_dir .. "/" .. name
                    end
                end
            end
        end
    end

    return index
end

function Engine.rangeCacheStatus(book_dir, start_page, end_page, cfg, cache_index)
    local summary = {
        start_page = math.floor(tonumber(start_page) or 0),
        end_page = math.floor(tonumber(end_page) or 0),
        total = 0,
        complete = 0,
        partial = 0,
        missing = 0,
        skipped = 0,
        bytes = 0,
        pages = {},
    }
    if summary.start_page < 1 or summary.end_page < summary.start_page then
        return summary
    end

    if not cacheIndexCovers(cache_index, book_dir, summary.start_page, summary.end_page) then
        cache_index = Engine.buildCacheStatusIndex(book_dir, summary.start_page, summary.end_page)
    end

    if cache_index.ok == false then
        for page = summary.start_page, summary.end_page do
            local status = Engine.pageCacheStatus(book_dir, page, cfg)
            summary.pages[#summary.pages + 1] = status
            summary.total = summary.total + 1
            summary.bytes = summary.bytes + (tonumber(status.bytes) or 0)
            if status.state == "complete" then
                summary.complete = summary.complete + 1
            elseif status.state == "partial" then
                summary.partial = summary.partial + 1
            elseif status.state == "skipped" then
                summary.skipped = summary.skipped + 1
            else
                summary.missing = summary.missing + 1
            end
        end
        summary.ready = summary.complete + summary.skipped
        summary.remaining = summary.total - summary.ready
        summary.percent = summary.total > 0 and (summary.ready / summary.total) or 0
        return summary
    end
    local pages_by_number = cache_index.pages_by_number or {}

    local preferred_ext, fallback_ext = cacheAudioExts(cfg)

    for page = summary.start_page, summary.end_page do
        local status = pageCacheStatusFromIndexedPage(
            book_dir,
            page,
            pages_by_number[page],
            preferred_ext,
            fallback_ext
        )

        summary.pages[#summary.pages + 1] = status
        summary.total = summary.total + 1
        summary.bytes = summary.bytes + (tonumber(status.bytes) or 0)
        if status.state == "complete" then
            summary.complete = summary.complete + 1
        elseif status.state == "partial" then
            summary.partial = summary.partial + 1
        elseif status.state == "skipped" then
            summary.skipped = summary.skipped + 1
        else
            summary.missing = summary.missing + 1
        end
    end
    summary.ready = summary.complete + summary.skipped
    summary.remaining = summary.total - summary.ready
    summary.percent = summary.total > 0 and (summary.ready / summary.total) or 0
    return summary
end

function Engine.normalizeText(text)
    if type(text) ~= "string" then
        return ""
    end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", " ")
    text = text:gsub("[ \t]+", " ")
    text = text:gsub("\n%s+", "\n"):gsub("%s+\n", "\n")
    text = text:gsub("\n\n+", "\n\n")
    return util.trim(text)
end

function Engine.textToLines(text)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = Engine.normalizeText(line)
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    return lines
end

function Engine.extractPageLines(document, page)
    if not document then
        return {}
    end

    if document.getPageXPointer and document.getTextFromXPointers then
        local ok, text = pcall(function()
            local start_xpointer = document:getPageXPointer(page)
            local end_xpointer = document:getPageXPointer(page + 1)
            if not start_xpointer or start_xpointer == "" or not end_xpointer or end_xpointer == "" then
                return nil
            end
            return document:getTextFromXPointers(start_xpointer, end_xpointer, false)
        end)
        if ok and type(text) == "string" then
            return Engine.textToLines(text)
        end
    end

    if not document.getTextBoxes then
        return {}
    end

    local ok, boxes = pcall(function()
        return document:getTextBoxes(page)
    end)
    if not ok or type(boxes) ~= "table" then
        return {}
    end

    local lines = {}
    for _, line in ipairs(boxes) do
        local words = {}
        if type(line) == "table" then
            for _, box in ipairs(line) do
                local word = type(box) == "table" and box.word
                if type(word) == "string" and word ~= "" then
                    words[#words + 1] = word
                end
            end
        end
        local line_text = table.concat(words, " ")
        if line_text ~= "" then
            local prev = lines[#lines]
            if prev and prev:sub(-1) == "-" and prev ~= "-" then
                lines[#lines] = prev:sub(1, -2) .. line_text
            else
                lines[#lines + 1] = line_text
            end
        end
    end

    local clean = {}
    for _, line in ipairs(lines) do
        line = Engine.normalizeText(line)
        if line ~= "" then
            clean[#clean + 1] = line
        end
    end
    return clean
end

function Engine.linesToText(lines)
    return Engine.normalizeText(table.concat(lines or {}, "\n"))
end

function Engine.extractPageText(document, page)
    return Engine.linesToText(Engine.extractPageLines(document, page))
end

function Engine.writePageLines(book_dir, page, lines)
    local path = Engine.pageLinesPath(book_dir, page)
    local tmp = path .. ".tmp"
    local file = assert(io.open(tmp, "w"))
    for _, line in ipairs(lines or {}) do
        file:write((line:gsub("\n", " ")), "\n")
    end
    file:close()
    os.rename(tmp, path)
end

function Engine.readPageLines(book_dir, page)
    local file = io.open(Engine.pageLinesPath(book_dir, page), "r")
    if not file then
        return nil
    end
    local lines = {}
    for line in file:lines() do
        lines[#lines + 1] = line
    end
    file:close()
    return lines
end

local function utf8SafeCut(text, limit)
    local cut = math.min(#text, limit)
    while cut > 1 do
        local byte = text:byte(cut)
        if not byte or byte < 128 or byte >= 192 then
            break
        end
        cut = cut - 1
    end
    local byte = text:byte(cut)
    if byte and byte >= 192 then
        cut = cut - 1
    end
    return math.max(cut, 1)
end

function Engine.splitText(text, limit)
    text = Engine.normalizeText(text)
    limit = tonumber(limit) or Engine.defaults.request_char_limit
    if text == "" then
        return {}
    end
    if #text <= limit then
        return { text }
    end

    local chunks = {}
    while #text > limit do
        local cut
        local window = text:sub(1, limit)
        for pos in window:gmatch("()[%.%!%?%;:%)]%s+") do
            cut = pos
        end
        if not cut or cut < limit * 0.55 then
            for pos in window:gmatch("()%s+") do
                cut = pos
            end
        end
        if not cut or cut < limit * 0.35 then
            cut = utf8SafeCut(text, limit)
        end
        chunks[#chunks + 1] = Engine.normalizeText(text:sub(1, cut))
        text = Engine.normalizeText(text:sub(cut + 1))
    end
    if text ~= "" then
        chunks[#chunks + 1] = text
    end
    return chunks
end

function Engine.wrapLongLines(lines, limit)
    limit = tonumber(limit) or Engine.defaults.request_char_limit
    limit = math.max(128, limit)

    local wrapped = {}
    for _, line in ipairs(lines or {}) do
        line = Engine.normalizeText(line)
        while #line > limit do
            local cut
            local window = line:sub(1, limit)
            for pos in window:gmatch("()%s+") do
                cut = pos
            end
            if not cut or cut < limit * 0.35 then
                cut = utf8SafeCut(line, limit)
            end
            local part = Engine.normalizeText(line:sub(1, cut))
            if part ~= "" then
                wrapped[#wrapped + 1] = part
            end
            line = Engine.normalizeText(line:sub(cut + 1))
        end
        if line ~= "" then
            wrapped[#wrapped + 1] = line
        end
    end
    return wrapped
end

function Engine.ssmlEscape(text)
    return tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
        :gsub("'", "&apos;")
end

function Engine.lineMarkName(line_index)
    return string.format("l%05d", tonumber(line_index) or 0)
end

function Engine.buildLineChunks(lines, limit)
    lines = lines or {}
    limit = tonumber(limit) or Engine.defaults.request_char_limit
    local chunks = {}
    local first_line
    local last_line
    local size = 0

    for i, line in ipairs(lines) do
        local line_size = #line + 32
        if first_line and size + line_size > limit then
            chunks[#chunks + 1] = {
                first_line = first_line,
                last_line = last_line,
                total_lines = #lines,
            }
            first_line = nil
            last_line = nil
            size = 0
        end
        first_line = first_line or i
        last_line = i
        size = size + line_size
    end

    if first_line then
        chunks[#chunks + 1] = {
            first_line = first_line,
            last_line = last_line,
            total_lines = #lines,
        }
    end
    return chunks
end

function Engine.lineChunkText(lines, chunk)
    local selected = {}
    for i = chunk.first_line, chunk.last_line do
        selected[#selected + 1] = lines[i]
    end
    return Engine.linesToText(selected)
end

function Engine.lineChunkSSML(lines, chunk)
    local parts = { "<speak>" }
    for i = chunk.first_line, chunk.last_line do
        parts[#parts + 1] = '<mark name="' .. Engine.lineMarkName(i) .. '"/>'
        parts[#parts + 1] = Engine.ssmlEscape(lines[i])
        if i < chunk.last_line then
            parts[#parts + 1] = '<break strength="weak"/>'
        end
    end
    parts[#parts + 1] = "</speak>"
    return table.concat(parts)
end

function Engine.timepointsByLine(timepoints)
    local by_line = {}
    if type(timepoints) ~= "table" then
        return by_line
    end
    for _, point in ipairs(timepoints) do
        local line = type(point) == "table" and tostring(point.markName or ""):match("^l(%d+)$")
        local seconds = type(point) == "table" and tonumber(point.timeSeconds)
        if line and seconds then
            by_line[#by_line + 1] = {
                line = tonumber(line),
                seconds = seconds,
            }
        end
    end
    table.sort(by_line, function(a, b)
        return a.seconds < b.seconds
    end)
    return by_line
end

local function timepointIndexAt(points, elapsed)
    local low, high = 1, #points
    local index = 1
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local seconds = tonumber(points[mid] and points[mid].seconds)
        if seconds and seconds <= elapsed then
            index = mid + 1
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return index
end

local function lineBeforeTimepoint(points, index, fallback)
    local point = index > 1 and points[index - 1]
    return (point and tonumber(point.line)) or fallback
end

function Engine.lineAndNextDelayFrom(meta, elapsed, speed, min_delay, max_delay, start_index, current_line)
    if type(meta) ~= "table" then
        return nil, tonumber(max_delay) or 0.8, 1
    end
    local points = meta.timepoints or {}
    local count = #points
    local current = tonumber(current_line) or tonumber(meta.first_line)
    elapsed = tonumber(elapsed) or 0
    speed = tonumber(speed) or 1
    if speed <= 0 then
        speed = 1
    end
    min_delay = tonumber(min_delay) or 0.12
    max_delay = tonumber(max_delay) or 0.8
    if count == 0 then
        return current, max_delay, 1
    end

    local raw_index = tonumber(start_index)
    local index = math.max(1, math.min(raw_index or 1, count + 1))
    local random_access = raw_index == nil
    if not random_access and index > 1 then
        local previous_seconds = tonumber(points[index - 1] and points[index - 1].seconds)
        random_access = previous_seconds and elapsed < previous_seconds
    end
    if random_access then
        index = timepointIndexAt(points, elapsed)
        current = lineBeforeTimepoint(points, index, tonumber(meta.first_line))
    end
    for i = index, count do
        local point = points[i]
        local seconds = tonumber(point.seconds)
        if seconds and seconds <= elapsed then
            current = tonumber(point.line) or current
            index = i + 1
        elseif seconds then
            return current, clamp((seconds - elapsed) / speed, min_delay, max_delay), index
        else
            break
        end
    end
    return current, max_delay, count + 1
end

function Engine.lineAndNextDelay(meta, elapsed, speed, min_delay, max_delay)
    local line, delay = Engine.lineAndNextDelayFrom(meta, elapsed, speed, min_delay, max_delay)
    return line, delay
end

function Engine.lineAtElapsed(meta, elapsed)
    local line = Engine.lineAndNextDelay(meta, elapsed)
    return line
end

function Engine.nextLineDelay(meta, elapsed, speed, min_delay, max_delay)
    local _, delay = Engine.lineAndNextDelay(meta, elapsed, speed, min_delay, max_delay)
    return delay
end

function Engine.googleRequestJSON(input, cfg)
    local request_input
    local enable_timepoints
    if type(input) == "table" then
        if input.ssml then
            request_input = { ssml = input.ssml }
            enable_timepoints = input.enable_timepoints
        else
            request_input = { text = input.text or "" }
        end
    else
        request_input = {
            text = input,
        }
    end
    cfg = cfg or {}
    local sample_rate_hz = tonumber(cfg.sample_rate_hz) or Engine.defaults.sample_rate_hz
    local body = {
        input = request_input,
        voice = {
            languageCode = cfg.language_code or Engine.defaults.language_code,
            name = cfg.voice_name or Engine.defaults.voice_name,
        },
        audioConfig = {
            audioEncoding = Engine.normalizeAudioEncoding(cfg.audio_encoding),
            speakingRate = tonumber(cfg.speaking_rate) or Engine.defaults.speaking_rate,
            pitch = tonumber(cfg.pitch) or Engine.defaults.pitch,
            volumeGainDb = tonumber(cfg.volume_gain_db) or Engine.defaults.volume_gain_db,
        },
    }
    if sample_rate_hz > 0 then
        body.audioConfig.sampleRateHertz = sample_rate_hz
    end
    if enable_timepoints then
        body.enableTimePointing = { "SSML_MARK" }
    end
    return rapidjson.encode(body)
end

function Engine.parseFormEncoded(body)
    local url = require("socket.url")
    local parsed = {}
    for pair in tostring(body or ""):gmatch("[^&]+") do
        local key, value = pair:match("^([^=]*)=?(.*)$")
        key = url.unescape((key or ""):gsub("+", " "))
        value = url.unescape((value or ""):gsub("+", " "))
        parsed[key] = value
    end
    return parsed
end

function Engine.htmlEscape(text)
    return tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
end

return Engine
