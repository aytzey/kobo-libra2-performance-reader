describe("TTSReader plugin engine", function()
    local Engine

    setup(function()
        require("commonrequire")
        package.path = "plugins/ttsreader.koplugin/?.lua;" .. package.path
        Engine = require("ttsengine")
    end)

    it("extracts readable text from page text boxes", function()
        local document = {
            getTextBoxes = function(_, page)
                assert.are.equal(12, page)
                return {
                    {
                        { word = "Merhaba" },
                        { word = "dunya" },
                    },
                    {
                        { word = "oku-" },
                    },
                    {
                        { word = "yucu" },
                    },
                    {
                        { word = "" },
                    },
                }
            end,
        }

        assert.are.equal("Merhaba dunya\nokuyucu", Engine.extractPageText(document, 12))
        assert.are.same({ "Merhaba dunya", "okuyucu" }, Engine.extractPageLines(document, 12))
    end)

    it("extracts reflowable EPUB text between page XPointers", function()
        local document = {
            getPageXPointer = function(_, page)
                return page <= 13 and "page-" .. page or nil
            end,
            getTextFromXPointers = function(_, first, last, draw_selection)
                assert.are.equal("page-12", first)
                assert.are.equal("page-13", last)
                assert.is_false(draw_selection)
                return "First paragraph.\n\nSecond paragraph."
            end,
        }

        assert.are.same(
            { "First paragraph.", "Second paragraph." },
            Engine.extractPageLines(document, 12)
        )
    end)

    it("splits long text on useful boundaries", function()
        local parts = Engine.splitText("Birinci cumle. Ikinci cumle uzun. Ucuncu cumle.", 24)

        assert.are.same({
            "Birinci cumle.",
            "Ikinci cumle uzun.",
            "Ucuncu cumle.",
        }, parts)
    end)

    it("wraps very long lines before request chunking", function()
        local long = string.rep("kelime ", 40)
        local lines = Engine.wrapLongLines({ long }, 128)

        assert.truthy(#lines > 1)
        assert.are.equal(Engine.normalizeText(long), table.concat(lines, " "))
        for _, line in ipairs(lines) do
            assert.truthy(#line <= 128)
        end
    end)

    it("builds a compact Google TTS MP3 request body by default", function()
        local json = require("rapidjson")
        local body = json.decode(Engine.googleRequestJSON("Merhaba", {
            language_code = "tr-TR",
            voice_name = "tr-TR-Wavenet-E",
            speaking_rate = 1.05,
            pitch = 0,
            volume_gain_db = 0,
        }))

        assert.are.equal("Merhaba", body.input.text)
        assert.are.equal("tr-TR", body.voice.languageCode)
        assert.are.equal("tr-TR-Wavenet-E", body.voice.name)
        assert.are.equal("MP3", body.audioConfig.audioEncoding)
        assert.are.equal(22050, body.audioConfig.sampleRateHertz)
        assert.are.equal(1.05, body.audioConfig.speakingRate)
    end)

    it("migrates the old large PCM cache format to MP3", function()
        local config = Engine.readConfig({
            data = {
                google_tts = {
                    audio_encoding = "LINEAR16",
                },
            },
        })

        assert.are.equal("MP3", config.audio_encoding)
    end)

    it("keeps narration language choices separate without moving legacy caches", function()
        local english = Engine.narrationVoice("en")
        local legacy_id = Engine.bookId("/books/a.epub", "A")
        local english_id = Engine.bookId(
            "/books/a.epub",
            "A",
            Engine.narrationVoiceCacheKey(english)
        )

        assert.are.equal("en-US", english.language_code)
        assert.are.equal("en-US-Wavenet-D", english.voice_name)
        assert.is_nil(Engine.narrationVoice("unknown"))
        assert.are_not.equal(legacy_id, english_id)
        assert.are.equal(legacy_id, Engine.bookId("/books/a.epub", "A", nil))
    end)

    it("normalizes playback speeds and labels them", function()
        assert.are.equal(1.2, Engine.normalizePlaybackSpeed(1.21))
        assert.are.equal(0.75, Engine.normalizePlaybackSpeed(0.8))
        assert.are.equal(1.5, Engine.nextPlaybackSpeed(1.2))
        assert.are.equal("1.5x", Engine.speedLabel(1.5))
    end)

    it("normalizes playback volume and labels it", function()
        assert.are.equal(0.8, Engine.normalizePlaybackVolume(0.82))
        assert.are.equal(1.2, Engine.adjustPlaybackVolume(1.0, 1))
        assert.are.equal(0.8, Engine.adjustPlaybackVolume(1.0, -1))
        assert.are.equal("120%", Engine.volumeLabel(1.2))
        assert.are.equal("21%", Engine.percentLabel(0.214))
        assert.are.equal("0%", Engine.percentLabel(nil))
    end)

    it("prioritizes incomplete cache states in page lists", function()
        assert.are.equal(1, Engine.cacheStateSortRank("missing"))
        assert.are.equal(2, Engine.cacheStateSortRank("partial"))
        assert.are.equal(3, Engine.cacheStateSortRank("skipped"))
        assert.are.equal(4, Engine.cacheStateSortRank("complete"))
        assert.truthy(Engine.cacheStateSortRank("unknown") > Engine.cacheStateSortRank("complete"))
    end)

    it("detects when visible page drifts from the playing audio page", function()
        assert.is_nil(Engine.playbackPageDrift(12, 12))
        assert.is_nil(Engine.playbackPageDrift(nil, 12))

        assert.are.same({
            current_page = 15,
            audio_page = 12,
            delta = 3,
        }, Engine.playbackPageDrift(15.8, 12))
    end)

    it("builds speed-aware player commands for supported players", function()
        local command, info = Engine.playerCommand("/usr/bin/mpv", "/mnt/book audio/p001.mp3", 1.5, 12.25)

        assert.truthy(command:find("--speed=1.5", 1, true))
        assert.truthy(command:find("--start=12.25", 1, true))
        assert.truthy(command:find("'/mnt/book audio/p001.mp3'", 1, true))
        assert.is_true(info.speed_supported)
        assert.is_true(info.seek_supported)
        assert.are.equal(1.5, info.effective_speed)
    end)

    it("identifies bundled native player paths", function()
        assert.is_true(Engine.isNativePlayer("./bin/ttsreader-play"))
        assert.is_true(Engine.isNativePlayer("/mnt/onboard/.adds/koreader/bin/ttsreader-play"))
        assert.is_false(Engine.isNativePlayer("/usr/bin/mpv"))
    end)

    it("prefers the bundled native player command shape", function()
        local command, info = Engine.playerCommand("./bin/ttsreader-play", "/tmp/a.mp3", 2.0, 5, "bluealsa:DEV=AA:BB", 0.8, "/tmp/volume.ctl")

        assert.truthy(command:find("./bin/ttsreader%-play", 1, false))
        assert.truthy(command:find("--device 'bluealsa:DEV=AA:BB'", 1, true))
        assert.truthy(command:find("--speed 2", 1, true))
        assert.truthy(command:find("--volume 0.8", 1, true))
        assert.truthy(command:find("--volume-control '/tmp/volume.ctl'", 1, true))
        assert.truthy(command:find("--seek 5", 1, true))
        assert.is_true(info.speed_supported)
        assert.is_true(info.seek_supported)
        assert.is_true(info.volume_supported)
        assert.is_true(info.live_volume_supported)
    end)

    it("builds Bluetooth audio device names from saved MAC addresses", function()
        assert.are.equal("default", Engine.bluetoothAudioDevice(""))
        assert.are.equal("bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp", Engine.bluetoothAudioDevice(" AA:BB:CC:DD:EE:FF "))
        assert.is_true(Engine.hasBluetoothAudio({ bluetooth_mac = "AA:BB:CC:DD:EE:FF" }))
        assert.is_false(Engine.hasBluetoothAudio({ bluetooth_mac = "AA:BB" }))
        assert.is_false(Engine.hasBluetoothAudio({ bluetooth_mac = "" }))
    end)

    it("requires Bluetooth device info to prove an active audio connection", function()
        assert.is_true(Engine.bluetoothInfoConnected(table.concat({
            "Attempting to connect to 88:C9:E8:AF:0E:4D",
            "::INFO::",
            "Device 88:C9:E8:AF:0E:4D WH-1000XM5",
            "\tConnected: yes",
        }, "\n")))

        assert.is_false(Engine.bluetoothInfoConnected(table.concat({
            "Failed to connect: org.bluez.Error.Failed br-connection-page-timeout",
            "::INFO::",
            "Device 88:C9:E8:AF:0E:4D WH-1000XM5",
            "\tConnected: no",
        }, "\n")))
    end)

    it("classifies Bluetooth reconnect failures for the player UI", function()
        assert.are.equal("not reachable", Engine.bluetoothConnectFailureStatus(
            "Failed to connect: org.bluez.Error.Failed br-connection-page-timeout",
            1
        ))
        assert.are.equal("connect timeout", Engine.bluetoothConnectFailureStatus(
            "::TTSREADER_BT_TIMEOUT::",
            124,
            "::TTSREADER_BT_TIMEOUT::"
        ))
        assert.are.equal("bt stack failed", Engine.bluetoothConnectFailureStatus(
            "::TTSREADER_BT_STACK_FAILED::",
            1,
            "::TTSREADER_BT_TIMEOUT::",
            "::TTSREADER_BT_STACK_FAILED::"
        ))
        assert.are.equal("pairing issue", Engine.bluetoothConnectFailureStatus(
            "Failed to connect: org.bluez.Error.AuthenticationFailed",
            1
        ))
        assert.are.equal("connect failed", Engine.bluetoothConnectFailureStatus(
            "Failed to connect: org.bluez.Error.Failed",
            1
        ))
    end)

    it("keeps high-touch Bluetooth player statuses short and local", function()
        assert.are.equal("bagli degil", Engine.bluetoothStatusLabel("not connected"))
        assert.are.equal("baglaniyor", Engine.bluetoothStatusLabel("connecting"))
        assert.are.equal("caliyor", Engine.bluetoothStatusLabel("streaming"))
        assert.are.equal("kontrol", Engine.bluetoothStatusLabel("checking"))
        assert.are.equal("baglanti koptu", Engine.bluetoothStatusLabel("connection lost"))
        assert.are.equal("bulunamadi", Engine.bluetoothStatusLabel("not reachable"))
        assert.are.equal("yeniden baglaniyor 1/2", Engine.bluetoothStatusLabel("reconnecting 1/2"))
        assert.are.equal("custom", Engine.bluetoothStatusLabel("custom"))
        assert.are.equal("Kulaklik bagli degil", Engine.bluetoothHeaderLabel("not connected"))
        assert.are.equal("", Engine.bluetoothHeaderLabel(""))
    end)

    it("uses the connected fast path and scans only after connect fails", function()
        local script = Engine.bluetoothConnectScript("88:c9:e8:af:0e:4d", false)

        assert.truthy(script:find("ensure_bluealsa || exit 1", 1, true))
        assert.truthy(script:find("--a2dp-force-mono", 1, true))
        assert.truthy(script:find("Connected: yes", 1, true))
        local connect_at = assert(script:find("bt 9 connect '88:C9:E8:AF:0E:4D'", 1, true))
        local scan_at = assert(script:find("bt 2 scan on", 1, true))
        assert.truthy(connect_at < scan_at)
        assert.truthy(script:find("bt_scan_off_quiet", 1, true))
        assert.truthy(script:find("if [ \"$connect_rc\" -ne 0 ]; then", 1, true))
        assert.truthy(script:find("::INFO::", 1, true))
        assert.truthy(script:find("bt 4 info '88:C9:E8:AF:0E:4D'", 1, true))
        assert.is_nil(script:find("agent on", 1, true))
        assert.is_nil(script:find("pairable on", 1, true))
        assert.is_nil(Engine.bluetoothConnectScript("not-a-mac", false))
    end)

    it("disconnects before Bluetooth reconnect only when refresh is requested", function()
        local normal = Engine.bluetoothConnectScript("88:C9:E8:AF:0E:4D", false)
        local refresh = Engine.bluetoothConnectScript("88:C9:E8:AF:0E:4D", true)

        assert.is_nil(normal:match("^bt 5 disconnect"))
        assert.truthy(refresh:find("bt 5 disconnect '88:C9:E8:AF:0E:4D' >/tmp/ttsreader%-bluetooth%-refresh%.log 2>&1 || true", 1, false))
    end)

    it("powers the idle Bluetooth stack down without forgetting pairing", function()
        local script = Engine.bluetoothPowerOffScript()

        assert.truthy(script:find("hciconfig hci0 down", 1, true))
        assert.truthy(script:find("killall -q -TERM bluealsa bluetoothd rtk_hciattach", 1, true))
        assert.truthy(script:find("rmmod sdio_bt_pwr", 1, true))
        assert.is_nil(script:find("bluetoothctl remove", 1, true))
    end)

    it("keeps Bluetooth ready gates longer than the reconnect command timeout", function()
        local timeout = Engine.bluetoothConnectTimeoutSeconds(1.2)

        assert.truthy(timeout >= 24)
        assert.truthy(Engine.bluetoothReadyGateSeconds(1.2) > timeout)
        assert.are.equal(timeout, Engine.bluetoothConnectTimeoutSeconds(0.1))
        assert.are.equal(Engine.bluetoothReadyGateSeconds(1.2), Engine.bluetoothReadyGateSeconds(3.0))
    end)

    it("recognizes Bluetooth headset input device names without opening internal Kobo keys", function()
        assert.is_true(Engine.bluetoothInputNameMatches("WH-1000XM5"))
        assert.is_true(Engine.bluetoothInputNameMatches("Sony WH-1000XM5 AVRCP"))
        assert.is_true(Engine.bluetoothInputNameMatches("Bluetooth Headset"))
        assert.is_true(Engine.bluetoothInputNameMatches("WF-1000XM5"))

        assert.is_false(Engine.bluetoothInputNameMatches("Elan Touchscreen"))
        assert.is_false(Engine.bluetoothInputNameMatches("gpio-keys"))
        assert.is_false(Engine.bluetoothInputNameMatches("bd71828-pwrkey"))
    end)

    it("extracts Bluetooth media input events from proc input devices", function()
        local proc_input = table.concat({
            [[I: Bus=0018 Vendor=0000 Product=0000 Version=0000]],
            [[N: Name="Elan Touchscreen"]],
            [[H: Handlers=kbd mouse0 event0]],
            [[]],
            [[I: Bus=0019 Vendor=0001 Product=0001 Version=0100]],
            [[N: Name="gpio-keys"]],
            [[H: Handlers=kbd event3]],
            [[]],
            [[I: Bus=0005 Vendor=054c Product=0df0 Version=0231]],
            [[N: Name="WH-1000XM5 (AVRCP)"]],
            [[H: Handlers=kbd event5]],
            [[]],
            [[I: Bus=0005 Vendor=054c Product=0df0 Version=0231]],
            [[N: Name="Consumer Control"]],
            [[H: Handlers=kbd event6]],
            [[]],
            [[I: Bus=0005 Vendor=054c Product=0df0 Version=0231]],
            [[N: Name="Bluetooth Keyboard"]],
            [[H: Handlers=kbd event7]],
        }, "\n")
        local devices = Engine.bluetoothInputDevicesFromProc(proc_input)
        local paths = Engine.bluetoothInputDevicePathsFromProc(proc_input)

        assert.are.equal(2, #devices)
        assert.are.same({ name = "WH-1000XM5 (AVRCP)", path = "/dev/input/event5" }, devices[1])
        assert.are.same({ name = "Consumer Control", path = "/dev/input/event6" }, devices[2])
        assert.are.same({
            ["/dev/input/event5"] = "WH-1000XM5 (AVRCP)",
            ["/dev/input/event6"] = "Consumer Control",
        }, paths)
    end)

    it("keeps plugin UI loops from shadowing the gettext helper", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.is_nil(source:match("for%s+_,"))
    end)

    it("does not duplicate percent signs in numbered UI templates", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.is_nil(source:match("%%%d+%%%%"))
    end)

    it("keeps shell fallback player exit status observable", function()
        local chunk, err = loadfile("plugins/ttsreader.koplugin/main.lua")
        assert.truthy(chunk, err)

        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find("function TTSReader:_shellPlayerStatus", 1, true))
        assert.truthy(source:find("shell_player_status_paths", 1, true))
        assert.truthy(source:find("function TTSReader:_cleanupShellPlayerStatus", 1, true))
    end)

    it("uses local short labels for the high-touch audio menu", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find("Sesli okuma", 1, true))
        assert.truthy(source:find("Bu sayfadan dinle", 1, true))
        assert.truthy(source:find("TTS onbellegi", 1, true))
        assert.truthy(source:find("Bluetooth kulaklik", 1, true))
    end)

    it("keeps Bluetooth headset media controls wired for Kobo input", function()
        local plugin_file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local plugin_source = plugin_file:read("*a")
        plugin_file:close()

        local input_file = assert(io.open("frontend/device/input.lua", "r"))
        local input_source = input_file:read("*a")
        input_file:close()

        assert.truthy(plugin_source:find('HeadsetMute', 1, true))
        assert.truthy(input_source:find('keycode == "HeadsetVolumeDown"', 1, true))
        assert.truthy(input_source:find('keycode == "HeadsetVolumeUp"', 1, true))
        assert.truthy(input_source:find('keycode == "HeadsetPrevious"', 1, true))
        assert.truthy(input_source:find('keycode == "HeadsetNext"', 1, true))
        assert.truthy(plugin_source:find("function TTSReader:_scheduleHeadsetInputRefreshBurst", 1, true))
        assert.truthy(plugin_source:find("self:_scheduleHeadsetInputRefreshBurst()", 1, true))
        assert.truthy(plugin_source:find("now - self.headset_input_refresh_started_at < 20", 1, true))
        assert.truthy(plugin_source:find("{ 0.25, 0.8, 1.8, 3.6, 5.5, 8.5, 12.5, 18.0 }", 1, true))
    end)

    it("keeps the player bar static controls cached between line repaints", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find("function TTSReaderPlayerBar:_ensureStaticCache", 1, true))
        assert.truthy(source:find("function TTSReaderPlayerBar:_dynamicRect", 1, true))
        assert.truthy(source:find("self.static_bb = Blitbuffer.new(rect.w, rect.h, bb_type)", 1, true))
        assert.truthy(source:find("bb:blitFrom(self.static_bb, rect.x, rect.y, 0, 0, rect.w, rect.h)", 1, true))
        assert.truthy(source:find("function TTSReaderPlayerBar:freeCache", 1, true))
        assert.truthy(source:find("controls_bottom_inset = 26", 1, true))
        assert.truthy(source:find("controls_h - self.controls_bottom_inset", 1, true))
        assert.truthy(source:find("self.static_layout = layout", 1, true))
        assert.truthy(source:find("self.static_hitboxes = self:_registerLayoutHitboxes(layout, {})", 1, true))
        assert.truthy(source:find("self.static_layout = nil", 1, true))
        assert.truthy(source:find("self.static_hitboxes = nil", 1, true))
        assert.truthy(source:find("tostring(rect.x)", 1, true))
        assert.truthy(source:find("tostring(rect.y)", 1, true))
        assert.truthy(source:find("static_unchanged and bar:_dynamicRect(new_rect) or new_rect", 1, true))
    end)

    it("does not rescan headset input devices on every player bar repaint", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find("headset_input_bar_validate_interval = 15", 1, true))
        assert.truthy(source:find("headset_input_missing_scan_interval = 20", 1, true))
        assert.truthy(source:find("function TTSReader:_headsetInputBarRefreshNeeded", 1, true))
        assert.truthy(source:find("or self.headset_input_missing_scan_interval", 1, true))
        assert.truthy(source:find("local has_existing_bar = self.playback_bar ~= nil", 1, true))
        assert.truthy(source:find("if self:_headsetInputBarRefreshNeeded(has_existing_bar) then", 1, true))
    end)

    it("keeps Bluetooth discovery bounded and cleans scan state", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find("bt_show=\"$(bt 4 show 2>/dev/null || true)\"", 1, true))
        assert.is_nil(source:find("if bluetoothctl show 2>/dev/null | grep -q 'Discovering: yes'; then", 1, true))
        assert.truthy(source:find("scan_cleanup() {", 1, true))
        assert.truthy(source:find("trap 'scan_cleanup; exit 124' INT TERM", 1, true))
        assert.truthy(source:find(") | bt 14 >\"$scan_log\" 2>&1", 1, true))
        assert.truthy(source:find("bt_scan_off_quiet", 1, true))
        assert.truthy(source:find("echo ]] .. BT_TIMEOUT_MARKER .. [[", 1, true))
        assert.truthy(source:find("bt 4 devices 2>/dev/null", 1, true))
        assert.truthy(source:find("bt 4 paired-devices 2>/dev/null", 1, true))
    end)

    it("uses native ALSA failure recovery and shuts Bluetooth down when idle", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()
        local engine_file = assert(io.open("plugins/ttsreader.koplugin/ttsengine.lua", "r"))
        local engine_source = engine_file:read("*a")
        engine_file:close()

        assert.truthy(source:find("bluetooth_idle_poweroff_seconds = 90", 1, true))
        assert.truthy(source:find("function TTSReader:_scheduleBluetoothIdleShutdown(delay)", 1, true))
        assert.truthy(source:find("self.playback and self.playback.pid", 1, true))
        assert.truthy(source:find("function TTSReader:_markBluetoothAudioActive()", 1, true))
        assert.truthy(source:find("self:_cancelBluetoothIdleShutdown()", 1, true))
        assert.truthy(source:find("Engine.bluetoothPowerOffScript", 1, true))
        assert.is_nil(source:find("function TTSReader:_startBluetoothLinkWatchdog()", 1, true))
        assert.is_nil(engine_source:find("bluetooth_link_check_seconds", 1, true))
    end)

    it("moves synthesized audio into cache without reading the blob through Lua", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.is_nil(source:find("readFile(job.audio_path)", 1, true))
        assert.truthy(source:find("function TTSReader:_detachAsyncJobExtraFile", 1, true))
        assert.truthy(source:find("moveFile(audio_path, tmp)", 1, true))
    end)

    it("runs heavy TTS synthesis workers at background priority", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find("local worker_args = table.concat({", 1, true))
        assert.truthy(source:find("exec ionice -c 3 nice -n 19 ", 1, true))
        assert.truthy(source:find("elif command -v nice >/dev/null 2>&1; then exec nice -n 19 ", 1, true))
        assert.truthy(source:find("else exec \" .. worker_args .. \"; fi", 1, true))
    end)

    it("does not repaint the generation bar when visible progress is unchanged", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find("function TTSReader:_generationRenderKey()", 1, true))
        assert.truthy(source:find("self.generation_bar_render_key = nil", 1, true))
        assert.truthy(source:find("local render_key = self:_generationRenderKey()", 1, true))
        assert.truthy(source:find("if not rebuild and not layout_changed and self.generation_bar_render_key == render_key then", 1, true))
        assert.truthy(source:find("self.generation_bar_render_key = render_key", 1, true))
    end)

    it("parses scanned and paired Bluetooth device rows", function()
        local devices = Engine.parseBluetoothDevices(table.concat({
            "Device 11:22:33:44:55:66 Keyboard",
            "[NEW] Device AA:BB:CC:DD:EE:FF WH-1000XM5",
            "[\1\27[0;92m\2NEW\1\27[0m\2] Device 88:C9:E8:AF:0E:4D WH-1000XM5",
            "Device not-a-mac Broken",
            "::PAIRED::",
            "[bluetooth]# Device AA:BB:CC:DD:EE:FF WH-1000XM5",
        }, "\n"))

        assert.are.equal(3, #devices)
        assert.are.equal("AA:BB:CC:DD:EE:FF", devices[1].mac)
        assert.are.equal("WH-1000XM5", devices[1].name)
        assert.is_true(devices[1].paired)
        assert.are.equal("11:22:33:44:55:66", devices[2].mac)
        assert.is_false(devices[2].paired)
        assert.are.equal("88:C9:E8:AF:0E:4D", devices[3].mac)
        assert.are.equal("WH-1000XM5", devices[3].name)
        assert.is_false(devices[3].paired)
    end)

    it("does not fake unsupported speed controls", function()
        local command, info = Engine.playerCommand("/usr/bin/madplay", "/tmp/a.mp3", 2.0, 8, nil, 1.5)

        assert.truthy(command:find("madplay", 1, true))
        assert.is_false(info.speed_supported)
        assert.is_false(info.seek_supported)
        assert.is_false(info.volume_supported)
        assert.are.equal(1.0, info.effective_speed)
        assert.are.equal(1.0, info.effective_volume)
    end)

    it("supports custom player placeholders for speed, seek, volume, and device", function()
        local command, info = Engine.playerCommand("custom --tempo {speed} --seek {seek} --volume {volume} --device {device} {file}", "/tmp/a'b.mp3", 0.75, 4, "bluealsa:DEV=AA:BB", 1.5)

        assert.truthy(command:find("--tempo 0.75", 1, true))
        assert.truthy(command:find("--seek 4", 1, true))
        assert.truthy(command:find("--volume 1.5", 1, true))
        assert.truthy(command:find("--device 'bluealsa:DEV=AA:BB'", 1, true))
        assert.truthy(command:find([['/tmp/a'"'"'b.mp3']], 1, true))
        assert.is_true(info.speed_supported)
        assert.is_true(info.seek_supported)
        assert.is_true(info.volume_supported)
    end)

    it("builds line chunks with SSML marks for timepoint tracking", function()
        local lines = {
            "Birinci satir & ozel",
            "Ikinci satir",
            "Ucuncu satir",
        }
        local chunks = Engine.buildLineChunks(lines, 96)

        assert.are.equal(2, #chunks)
        assert.are.same({
            first_line = 1,
            last_line = 2,
            total_lines = 3,
        }, chunks[1])

        local ssml = Engine.lineChunkSSML(lines, chunks[1])
        assert.truthy(ssml:find('<mark name="l00001"/>', 1, true))
        assert.truthy(ssml:find("Birinci satir &amp; ozel", 1, true))
        assert.truthy(ssml:find('<mark name="l00002"/>', 1, true))
    end)

    it("enables Google SSML timepoints when requested", function()
        local json = require("rapidjson")
        local body = json.decode(Engine.googleRequestJSON({
            ssml = '<speak><mark name="l00001"/>Merhaba</speak>',
            enable_timepoints = true,
        }, {
            language_code = "tr-TR",
            voice_name = "tr-TR-Wavenet-E",
            audio_encoding = "MP3",
        }))

        assert.are.equal('<speak><mark name="l00001"/>Merhaba</speak>', body.input.ssml)
        assert.are.same({ "SSML_MARK" }, body.enableTimePointing)
    end)

    it("maps Google timepoints back to page lines", function()
        local points = Engine.timepointsByLine({
            { markName = "l00003", timeSeconds = 3.5 },
            { markName = "ignored", timeSeconds = 1.0 },
            { markName = "l00001", timeSeconds = 0.1 },
        })

        assert.are.same({
            { line = 1, seconds = 0.1 },
            { line = 3, seconds = 3.5 },
        }, points)
        assert.are.equal(3, Engine.lineAtElapsed({
            first_line = 1,
            timepoints = points,
        }, 4.0))
        assert.are.equal(0.12, Engine.nextLineDelay({
            first_line = 1,
            timepoints = points,
        }, 0.0, 1.0, 0.12, 1.5))
        assert.are.equal(1.0, Engine.nextLineDelay({
            first_line = 1,
            timepoints = points,
        }, 1.5, 2.0, 0.12, 1.5))
        local line, delay = Engine.lineAndNextDelay({
            first_line = 1,
            timepoints = points,
        }, 1.5, 2.0, 0.12, 1.5)
        assert.are.equal(1, line)
        assert.are.equal(1.0, delay)
        assert.are.equal(1.5, Engine.nextLineDelay({
            first_line = 1,
            timepoints = points,
        }, 4.0, 1.0, 0.12, 1.5))
    end)

    it("advances playback line timepoints incrementally", function()
        local meta = {
            first_line = 1,
            timepoints = {
                { line = 1, seconds = 0.25 },
                { line = 2, seconds = 1.0 },
                { line = 3, seconds = 2.0 },
            },
        }

        local line, delay, index = Engine.lineAndNextDelayFrom(meta, 1.2, 1.0, 0.12, 1.5)
        assert.are.equal(2, line)
        assert.are.equal(0.8, delay)
        assert.are.equal(3, index)

        line, delay, index = Engine.lineAndNextDelayFrom(meta, 1.8, 1.0, 0.12, 1.5, index, line)
        assert.are.equal(2, line)
        assert.truthy(math.abs(delay - 0.2) < 0.0001)
        assert.are.equal(3, index)

        line, delay, index = Engine.lineAndNextDelayFrom(meta, 0.1, 1.0, 0.12, 1.5, index, line)
        assert.are.equal(1, line)
        assert.are.equal(0.15, delay)
        assert.are.equal(1, index)
    end)

    it("seeks playback timepoints without scanning from the first line", function()
        local points = {}
        for i = 1, 1000 do
            points[i] = { line = i, seconds = i * 0.5 }
        end
        local meta = {
            first_line = 1,
            timepoints = points,
        }

        local line, delay, index = Engine.lineAndNextDelayFrom(meta, 400.25, 1.0, 0.12, 1.5)
        assert.are.equal(800, line)
        assert.truthy(math.abs(delay - 0.25) < 0.0001)
        assert.are.equal(801, index)

        line, delay, index = Engine.lineAndNextDelayFrom(meta, 10.2, 1.0, 0.12, 1.5, 900, 899)
        assert.are.equal(20, line)
        assert.truthy(math.abs(delay - 0.3) < 0.0001)
        assert.are.equal(21, index)
    end)

    it("parses LAN setup form data", function()
        local form = Engine.parseFormEncoded("api_key=abc%2B123&voice_name=tr-TR-Wavenet-E&language_code=tr-TR")

        assert.are.equal("abc+123", form.api_key)
        assert.are.equal("tr-TR-Wavenet-E", form.voice_name)
        assert.are.equal("tr-TR", form.language_code)
    end)

    it("tracks completed page audio segments", function()
        local dir = Engine.cache_dir .. "/unit-test"
        Engine.ensureDir(dir)
        local first = Engine.segmentPath(dir, 7, 1, { audio_encoding = "LINEAR16" })
        local second = Engine.segmentPath(dir, 7, 2, { audio_encoding = "LINEAR16" })
        local file = assert(io.open(first, "w"))
        file:write("a")
        file:close()
        file = assert(io.open(second, "w"))
        file:write("b")
        file:close()

        Engine.markPageDone(dir, 7, 2)
        Engine.writeSegmentMeta(dir, 7, 1, {
            first_line = 1,
            last_line = 2,
            total_lines = 3,
            timepoints = {
                { line = 1, seconds = 0 },
            },
        })
        assert.are.same({ first, second }, Engine.generatedSegments(dir, 7, { audio_encoding = "LINEAR16" }))
        assert.are.equal(1, Engine.generatedSegmentEntries(dir, 7, { audio_encoding = "LINEAR16" })[1].meta.first_line)

        os.remove(first)
        os.remove(second)
        os.remove(Engine.segmentMetaPath(dir, 7, 1))
        os.remove(Engine.donePath(dir, 7))
        os.remove(dir)
    end)

    it("falls back to older MP3 cache when fast WAV segments are missing", function()
        local dir = Engine.cache_dir .. "/unit-test-mp3-fallback"
        Engine.ensureDir(dir)
        local first = Engine.segmentPathForEncoding(dir, 8, 1, "MP3")
        local file = assert(io.open(first, "w"))
        file:write("a")
        file:close()

        Engine.markPageDone(dir, 8, 1)
        Engine.writeSegmentMeta(dir, 8, 1, {
            first_line = 1,
            last_line = 1,
            total_lines = 1,
        })

        assert.are.same({ first }, Engine.generatedSegments(dir, 8, { audio_encoding = "LINEAR16" }))
        assert.are.equal(first, Engine.generatedSegmentEntries(dir, 8, { audio_encoding = "LINEAR16" })[1].path)

        os.remove(first)
        os.remove(Engine.segmentMetaPath(dir, 8, 1))
        os.remove(Engine.donePath(dir, 8))
        os.remove(dir)
    end)

    it("reports complete, partial, and missing page cache states", function()
        local dir = Engine.cache_dir .. "/unit-test-cache-status"
        Engine.ensureDir(dir)
        local first = Engine.segmentPath(dir, 9, 1, { audio_encoding = "LINEAR16" })
        local second = Engine.segmentPath(dir, 9, 2, { audio_encoding = "LINEAR16" })
        local file = assert(io.open(first, "w"))
        file:write("a")
        file:close()
        Engine.markPageDone(dir, 9, 2)
        Engine.writeSegmentMeta(dir, 9, 1, {
            first_line = 1,
            last_line = 1,
            total_lines = 2,
        })

        local status = Engine.pageCacheStatus(dir, 9, { audio_encoding = "LINEAR16" })
        assert.are.equal("partial", status.state)
        assert.are.equal(2, status.segment_count)
        assert.are.equal(1, status.audio_count)
        assert.are.equal(1, status.meta_count)

        file = assert(io.open(second, "w"))
        file:write("b")
        file:close()
        Engine.writeSegmentMeta(dir, 9, 2, {
            first_line = 2,
            last_line = 2,
            total_lines = 2,
        })

        status = Engine.pageCacheStatus(dir, 9, { audio_encoding = "LINEAR16" })
        assert.are.equal("complete", status.state)
        assert.is_true(Engine.isPageComplete(dir, 9, { audio_encoding = "LINEAR16" }))

        local removed = Engine.clearPageCache(dir, 9)
        assert.truthy(removed >= 5)
        status = Engine.pageCacheStatus(dir, 9, { audio_encoding = "LINEAR16" })
        assert.are.equal("missing", status.state)
        assert.is_false(Engine.isPageComplete(dir, 9, { audio_encoding = "LINEAR16" }))

        os.remove(dir)
    end)

    it("summarizes and clears TTS cache ranges", function()
        local dir = Engine.cache_dir .. "/unit-test-cache-range"
        Engine.ensureDir(dir)
        Engine.markPageSkipped(dir, 10, "empty")

        local path = Engine.segmentPath(dir, 11, 1, { audio_encoding = "LINEAR16" })
        local file = assert(io.open(path, "w"))
        file:write("a")
        file:close()
        Engine.markPageDone(dir, 11, 1)
        Engine.writeSegmentMeta(dir, 11, 1, {
            first_line = 1,
            last_line = 1,
            total_lines = 1,
        })

        Engine.markPageDone(dir, 12, 1)
        local outside_segment = Engine.segmentPath(dir, 13, 1, { audio_encoding = "LINEAR16" })
        file = assert(io.open(outside_segment, "w"))
        file:write("outside")
        file:close()
        Engine.markPageDone(dir, 13, 1)

        local summary = Engine.rangeCacheStatus(dir, 10, 12, { audio_encoding = "LINEAR16" })
        assert.are.equal(3, summary.total)
        assert.are.equal(1, summary.complete)
        assert.are.equal(1, summary.skipped)
        assert.are.equal(1, summary.partial)
        assert.are.equal(0, summary.missing)
        assert.are.equal(2, summary.ready)
        assert.are.equal(1, summary.remaining)

        local removed = Engine.clearPageRangeCache(dir, 10, 12)
        assert.are.equal(5, removed)
        summary = Engine.rangeCacheStatus(dir, 10, 12, { audio_encoding = "LINEAR16" })
        assert.are.equal(3, summary.missing)
        assert.are.equal(0, summary.ready)
        file = assert(io.open(outside_segment, "r"))
        file:close()
        file = assert(io.open(Engine.donePath(dir, 13), "r"))
        file:close()

        Engine.clearPageRangeCache(dir, 13, 13)
        os.remove(dir)
    end)

    it("matches per-page cache status while summarizing a range in one pass", function()
        local dir = Engine.cache_dir .. "/unit-test-cache-range-fast"
        local cfg = { audio_encoding = "LINEAR16" }
        Engine.ensureDir(dir)

        local file
        Engine.markPageDone(dir, 30, 2)
        Engine.writePageLines(dir, 30, { "cached text" })
        file = assert(io.open(Engine.segmentPathForEncoding(dir, 30, 1, "LINEAR16"), "w"))
        file:write("wav")
        file:close()
        file = assert(io.open(Engine.segmentPathForEncoding(dir, 30, 2, "MP3"), "w"))
        file:write("mp3")
        file:close()
        Engine.writeSegmentMeta(dir, 30, 1, {
            first_line = 1,
            last_line = 1,
            total_lines = 2,
        })
        file = assert(io.open(Engine.segmentMetaPath(dir, 30, 2), "w"))
        file:write("{")
        file:close()

        Engine.markPageSkipped(dir, 31, "empty")

        Engine.markPageDone(dir, 32, 1)
        file = assert(io.open(Engine.segmentPathForEncoding(dir, 32, 1, "MP3"), "w"))
        file:write("fallback")
        file:close()
        Engine.writeSegmentMeta(dir, 32, 1, {
            first_line = 1,
            last_line = 1,
            total_lines = 1,
        })

        local cache_index = Engine.buildCacheStatusIndex(dir, 30, 32)
        assert.is_true(cache_index.ok)
        local summary = Engine.rangeCacheStatus(dir, 30, 32, cfg, cache_index)
        assert.are.equal(3, summary.total)
        assert.are.equal(1, summary.complete)
        assert.are.equal(1, summary.partial)
        assert.are.equal(1, summary.skipped)
        assert.are.equal(0, summary.missing)

        local page, entries, skipped, status = Engine.nextPlayableSegmentEntries(dir, 30, 32, cfg, cache_index)
        assert.are.equal(30, page)
        assert.are.equal(0, skipped)
        assert.is_nil(status)
        assert.are.equal(2, #entries)
        assert.are.equal(Engine.segmentPathForEncoding(dir, 30, 1, "LINEAR16"), entries[1].path)
        assert.are.equal(Engine.segmentPathForEncoding(dir, 30, 2, "MP3"), entries[2].path)
        assert.truthy(entries[1].meta)
        assert.is_nil(entries[2].meta)

        for i, page in ipairs({ 30, 31, 32 }) do
            local expected = Engine.pageCacheStatus(dir, page, cfg)
            local actual = summary.pages[i]
            assert.are.equal(expected.page, actual.page)
            assert.are.equal(expected.state, actual.state)
            assert.are.equal(expected.segment_count, actual.segment_count)
            assert.are.equal(expected.audio_count, actual.audio_count)
            assert.are.equal(expected.meta_count, actual.meta_count)
            assert.are.equal(expected.bytes, actual.bytes)
            assert.are.equal(expected.has_lines, actual.has_lines)
            assert.are.equal(expected.has_done, actual.has_done)
            assert.are.equal(expected.skipped, actual.skipped)
        end

        Engine.clearPageRangeCache(dir, 30, 32)
        os.remove(dir)
    end)

    it("skips textless pages when looking for playable TTS segments", function()
        local dir = Engine.cache_dir .. "/unit-test-playable-skip"
        Engine.ensureDir(dir)
        Engine.markPageSkipped(dir, 20, "empty")
        Engine.markPageSkipped(dir, 21, "empty")

        local path = Engine.segmentPath(dir, 22, 1, { audio_encoding = "LINEAR16" })
        local file = assert(io.open(path, "w"))
        file:write("a")
        file:close()
        Engine.markPageDone(dir, 22, 1)
        Engine.writeSegmentMeta(dir, 22, 1, {
            first_line = 1,
            last_line = 1,
            total_lines = 1,
        })

        local page, entries, skipped, status = Engine.nextPlayableSegmentEntries(
            dir,
            20,
            25,
            { audio_encoding = "LINEAR16" }
        )
        assert.are.equal(22, page)
        assert.are.equal(2, skipped)
        assert.is_nil(status)
        assert.are.equal(path, entries[1].path)

        local missing_page, missing_entries, missing_skipped, missing_status =
            Engine.nextPlayableSegmentEntries(dir, 23, 25, { audio_encoding = "LINEAR16" })
        assert.is_nil(missing_page)
        assert.is_nil(missing_entries)
        assert.are.equal(0, missing_skipped)
        assert.are.equal("missing", missing_status.state)
        assert.are.equal(23, missing_status.page)

        Engine.clearPageRangeCache(dir, 20, 22)
        os.remove(dir)
    end)

    it("uses cached TTS page lines before extracting document text again", function()
        local file = assert(io.open("plugins/ttsreader.koplugin/main.lua", "r"))
        local source = file:read("*a")
        file:close()

        assert.truthy(source:find("Engine.readPageLines(book_dir, page)", 1, true))
        assert.truthy(source:find("cached_lines and #cached_lines > 0 and cached_lines or Engine.extractPageLines", 1, true))
        assert.truthy(source:find("if not cached_lines or #cached_lines == 0 then", 1, true))
        assert.truthy(source:find("Engine.buildCacheStatusIndex(book_dir, 1, page_count)", 1, true))
        assert.truthy(source:find("playback.cache_index", 1, true))
        assert.truthy(source:find("Engine.buildCacheStatusIndex(playback.book_dir, 1, playback.page_count)", 1, true))
    end)
end)
