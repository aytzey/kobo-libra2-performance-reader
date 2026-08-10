--[[
ReaderUI is an abstraction for a reader interface.

It works using data gathered from a document interface.
]]--

local Archiver = require("ffi/archiver")
local BD = require("ui/bidi")
local Device = require("device")
local DeviceListener = require("device/devicelistener")
local DocCache = require("document/doccache")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local PluginLoader = require("pluginloader")
local SettingsMigration = require("ui/data/settings_migration")
local UIManager = require("ui/uimanager")
local ffiUtil  = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local Input = Device.input
local Screen = Device.screen
local T = ffiUtil.template
local BookList
local FileManagerBookInfo
local FileManagerCollection
local FileManagerHistory
local FileManagerFileSearcher
local FileManagerShortcuts
local InfoMessage
local InputDialog
local LanguageSupport
local NetworkListener
local Notification
local ReaderDeviceStatus
local ReaderDictionary
local ReaderModules = {}
local ReaderWikipedia
local Screenshoter

local function lookupModulesDisabled()
    return G_reader_settings:isTrue("libra2_disable_lookup_modules")
end

local function lazyReaderSidePanels()
    return G_reader_settings:isTrue("libra2_lazy_reader_sidepanels")
end

local function getBookList()
    BookList = BookList or require("ui/widget/booklist")
    return BookList
end

local function getFileManagerBookInfo()
    FileManagerBookInfo = FileManagerBookInfo or require("apps/filemanager/filemanagerbookinfo")
    return FileManagerBookInfo
end

local function getFileManagerCollection()
    FileManagerCollection = FileManagerCollection or require("apps/filemanager/filemanagercollection")
    return FileManagerCollection
end

local function getFileManagerHistory()
    FileManagerHistory = FileManagerHistory or require("apps/filemanager/filemanagerhistory")
    return FileManagerHistory
end

local function getFileManagerFileSearcher()
    FileManagerFileSearcher = FileManagerFileSearcher or require("apps/filemanager/filemanagerfilesearcher")
    return FileManagerFileSearcher
end

local function getFileManagerShortcuts()
    FileManagerShortcuts = FileManagerShortcuts or require("apps/filemanager/filemanagershortcuts")
    return FileManagerShortcuts
end

local function getInfoMessage()
    InfoMessage = InfoMessage or require("ui/widget/infomessage")
    return InfoMessage
end

local function getInputDialog()
    InputDialog = InputDialog or require("ui/widget/inputdialog")
    return InputDialog
end

local function getLanguageSupport()
    LanguageSupport = LanguageSupport or require("languagesupport")
    return LanguageSupport
end

local function getNetworkListener()
    NetworkListener = NetworkListener or require("ui/network/networklistener")
    return NetworkListener
end

local function getNotification()
    Notification = Notification or require("ui/widget/notification")
    return Notification
end

local function getReaderDeviceStatus()
    ReaderDeviceStatus = ReaderDeviceStatus or require("apps/reader/modules/readerdevicestatus")
    return ReaderDeviceStatus
end

local function getReaderModule(module_name)
    ReaderModules[module_name] = ReaderModules[module_name]
        or require("apps/reader/modules/" .. module_name)
    return ReaderModules[module_name]
end

local function getScreenshoter()
    Screenshoter = Screenshoter or require("ui/widget/screenshoter")
    return Screenshoter
end

local ReaderSidePanelProxy = InputContainer:extend{
    target_name = nil,
    target_loader = nil,
    target = nil,
}

function ReaderSidePanelProxy:init()
    self.ui.menu:registerToMainMenu(self)
end

function ReaderSidePanelProxy:getTarget()
    if self.target then
        return self.target
    end
    local target = self.target_loader():new{
        dialog = self.dialog,
        ui = self.ui,
    }
    target.name = "reader" .. self.target_name
    self.target = target
    self.ui[self.target_name] = target
    table.insert(self.ui, target)
    return target
end

function ReaderSidePanelProxy:addToMainMenu(menu_items)
    if self.target then
        return self.target:addToMainMenu(menu_items)
    end
    if self.target_name == "history" then
        menu_items.history = {
            text = _("History"),
            callback = function()
                self:getTarget():onShowHist()
            end,
        }
    elseif self.target_name == "collections" then
        menu_items.favorites = {
            text = _("Favorites"),
            callback = function()
                self:getTarget():onShowColl()
            end,
        }
        menu_items.collections = {
            text = _("Collections"),
            callback = function()
                self:getTarget():onShowCollList()
            end,
        }
        menu_items.bookmark_browser = {
            text = _("Bookmark browser"),
            callback = function()
                self:getTarget():onShowBookmarkBrowser()
            end,
        }
    end
end

function ReaderSidePanelProxy:onShowHist(...)
    return self:getTarget():onShowHist(...)
end

function ReaderSidePanelProxy:onShowColl(...)
    return self:getTarget():onShowColl(...)
end

function ReaderSidePanelProxy:onShowCollList(...)
    return self:getTarget():onShowCollList(...)
end

function ReaderSidePanelProxy:onShowBookmarkBrowser(...)
    return self:getTarget():onShowBookmarkBrowser(...)
end

function ReaderSidePanelProxy:getCollectionTitle(...)
    return self:getTarget():getCollectionTitle(...)
end

function ReaderSidePanelProxy:genAddToCollectionButton(...)
    return self:getTarget():genAddToCollectionButton(...)
end

function ReaderSidePanelProxy:genExportHighlightsButton(...)
    return self:getTarget():genExportHighlightsButton(...)
end

function ReaderSidePanelProxy:genBookmarkBrowserButton(...)
    return self:getTarget():genBookmarkBrowserButton(...)
end

local ReaderUI = InputContainer:extend{
    name = "ReaderUI",
    active_widgets = nil, -- array

    -- if we have a parent container, it must be referenced for now
    dialog = nil,

    -- the document interface
    document = nil,

    -- password for document unlock
    password = nil,

    postInitCallback = nil,
    postReaderReadyCallback = nil,
}

function ReaderUI:registerModule(name, ui_module, always_active)
    if name then
        self[name] = ui_module
        ui_module.name = "reader" .. name
    end
    table.insert(self, ui_module)
    if always_active then
        -- to get events even when hidden
        table.insert(self.active_widgets, ui_module)
    end
end

function ReaderUI:registerPostInitCallback(callback)
    table.insert(self.postInitCallback, callback)
end

function ReaderUI:registerPostReaderReadyCallback(callback)
    table.insert(self.postReaderReadyCallback, callback)
end

function ReaderUI:init()
    self.active_widgets = {}

    -- cap screen refresh on pan to 2 refreshes per second
    local pan_rate = Screen.low_pan_rate and 2.0 or 30.0

    Input:inhibitInput(true) -- Inhibit any past and upcoming input events.
    Device:setIgnoreInput(true) -- Avoid ANRs on Android with unprocessed events.

    self.postInitCallback = {}
    self.postReaderReadyCallback = {}
    -- if we are not the top level dialog ourselves, it must be given in the table
    if not self.dialog then
        self.dialog = self
    end

    self.doc_settings = DocSettings:open(self.document.file)
    self.document.is_new = self.doc_settings:readSetting("doc_props") == nil
    -- Handle local settings migration
    SettingsMigration:migrateSettings(self.doc_settings)

    self:registerKeyEvents()

    -- a view container (so it must be child #1!)
    -- all paintable widgets need to be a child of reader view
    self:registerModule("view", getReaderModule("readerview"):new{
        dialog = self.dialog,
        dimen = self.dimen,
        ui = self,
        document = self.document,
    })
    -- goto link controller
    self:registerModule("link", getReaderModule("readerlink"):new{
        dialog = self.dialog,
        view = self.view,
        ui = self,
        document = self.document,
    })
    -- text highlight
    self:registerModule("highlight", getReaderModule("readerhighlight"):new{
        dialog = self.dialog,
        view = self.view,
        ui = self,
        document = self.document,
    })
    -- menu widget should be registered after link widget and highlight widget
    -- so that taps on link and highlight areas won't popup reader menu
    -- reader menu controller
    self:registerModule("menu", getReaderModule("readermenu"):new{
        view = self.view,
        ui = self
    })
    -- Handmade/custom ToC and hidden flows
    self:registerModule("handmade", getReaderModule("readerhandmade"):new{
        dialog = self.dialog,
        view = self.view,
        ui = self,
        document = self.document,
    })
    -- Table of content controller
    self:registerModule("toc", getReaderModule("readertoc"):new{
        dialog = self.dialog,
        view = self.view,
        ui = self
    })
    -- bookmark controller
    self:registerModule("bookmark", getReaderModule("readerbookmark"):new{
        dialog = self.dialog,
        view = self.view,
        ui = self,
        document = self.document,
    })
    self:registerModule("annotation", getReaderModule("readerannotation"):new{
        dialog = self.dialog,
        view = self.view,
        ui = self,
        document = self.document,
    })
    -- reader goto controller
    -- "goto" being a dirty keyword in Lua?
    self:registerModule("gotopage", getReaderModule("readergoto"):new{
        dialog = self.dialog,
        view = self.view,
        ui = self,
        document = self.document,
    })
    self:registerModule("languagesupport", getLanguageSupport():new{
        ui = self,
        document = self.document,
    })
    if not lookupModulesDisabled() then
        -- dictionary
        ReaderDictionary = ReaderDictionary or require("apps/reader/modules/readerdictionary")
        self:registerModule("dictionary", ReaderDictionary:new{
            dialog = self.dialog,
            view = self.view,
            ui = self,
            document = self.document,
        })
        -- wikipedia
        ReaderWikipedia = ReaderWikipedia or require("apps/reader/modules/readerwikipedia")
        self:registerModule("wikipedia", ReaderWikipedia:new{
            dialog = self.dialog,
            view = self.view,
            ui = self,
            document = self.document,
        })
    end
    if not G_reader_settings:isTrue("libra2_disable_reader_screenshot_module") then
        -- screenshot controller
        self:registerModule("screenshot", getScreenshoter():new{
            prefix = 'Reader',
            dialog = self.dialog,
            view = self.view,
            ui = self
        }, true)
    end
    if not G_reader_settings:isTrue("libra2_disable_reader_devicestatus_module") then
        -- device status controller
        self:registerModule("devicestatus", getReaderDeviceStatus():new{
            ui = self,
        })
    end
    -- configurable controller
    if self.document.info.configurable then
        -- config panel controller
        self:registerModule("config", getReaderModule("readerconfig"):new{
            configurable = self.document.configurable,
            dialog = self.dialog,
            view = self.view,
            ui = self,
            document = self.document,
        })
        if self.document.info.has_pages then
            -- kopt option controller
            self:registerModule("koptlistener", getReaderModule("readerkoptlistener"):new{
                dialog = self.dialog,
                view = self.view,
                ui = self,
                document = self.document,
            })
        else
            -- cre option controller
            self:registerModule("crelistener", getReaderModule("readercoptlistener"):new{
                dialog = self.dialog,
                view = self.view,
                ui = self,
                document = self.document,
            })
        end
        -- activity indicator for when some settings take time to take effect (Kindle under KPV)
        local ReaderActivityIndicator = getReaderModule("readeractivityindicator")
        if not ReaderActivityIndicator:isStub() then
            self:registerModule("activityindicator", ReaderActivityIndicator:new{
                dialog = self.dialog,
                view = self.view,
                ui = self,
                document = self.document,
            })
        end
    end
    -- for page specific controller
    if self.document.info.has_pages then
        -- cropping controller
        self:registerModule("cropping", getReaderModule("readercropping"):new{
            dialog = self.dialog,
            view = self.view,
            ui = self,
            document = self.document,
        })
        -- paging controller
        self:registerModule("paging", getReaderModule("readerpaging"):new{
            pan_rate = pan_rate,
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
        -- zooming controller
        self:registerModule("zooming", getReaderModule("readerzooming"):new{
            dialog = self.dialog,
            document = self.document,
            view = self.view,
            ui = self
        })
        -- panning controller
        self:registerModule("panning", getReaderModule("readerpanning"):new{
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
        -- hinting controller
        self:registerModule("hinting", getReaderModule("readerhinting"):new{
            dialog = self.dialog,
            zoom = self.zooming,
            view = self.view,
            ui = self,
            document = self.document,
        })
    else
        -- load crengine default settings (from cr3.ini, some of these
        -- will be overridden by our settings by some reader modules below)
        if self.document.setupDefaultView then
            self.document:setupDefaultView()
        end
        -- make sure we render document first before calling any callback
        self:registerPostInitCallback(function()
            local start_time = time.now()
            if not self.document:loadDocument() then
                self:dealWithLoadDocumentFailure()
            end
            logger.dbg(string.format("  loading took %.3f seconds", time.to_s(time.since(start_time))))

            -- used to read additional settings after the document has been
            -- loaded (but not rendered yet)
            self:handleEvent(Event:new("PreRenderDocument", self.doc_settings))

            start_time = time.now()
            self.document:render()
            logger.dbg(string.format("  rendering took %.3f seconds", time.to_s(time.since(start_time))))

            -- Uncomment to output the built DOM (for debugging)
            -- logger.dbg(self.document:getHTMLFromXPointer(".0", 0x6830))
        end)
        -- styletweak controller (must be before typeset controller)
        self:registerModule("styletweak", getReaderModule("readerstyletweak"):new{
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
        -- typeset controller
        self:registerModule("typeset", getReaderModule("readertypeset"):new{
            configurable = self.document.configurable,
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
        -- font menu
        self:registerModule("font", getReaderModule("readerfont"):new{
            configurable = self.document.configurable,
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
        -- user hyphenation (must be registered before typography)
        self:registerModule("userhyph", getReaderModule("readeruserhyph"):new{
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
        -- typography menu (replaces previous hyphenation menu / ReaderHyphenation)
        self:registerModule("typography", getReaderModule("readertypography"):new{
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
        -- rolling controller
        self:registerModule("rolling", getReaderModule("readerrolling"):new{
            configurable = self.document.configurable,
            pan_rate = pan_rate,
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
        -- pagemap controller
        self:registerModule("pagemap", getReaderModule("readerpagemap"):new{
            dialog = self.dialog,
            view = self.view,
            ui = self
        })
    end
    self.disable_double_tap = G_reader_settings:nilOrTrue("disable_double_tap")
    -- scrolling (scroll settings + inertial scrolling)
    self:registerModule("scrolling", getReaderModule("readerscrolling"):new{
        pan_rate = pan_rate,
        dialog = self.dialog,
        ui = self,
        view = self.view,
    })
    -- back location stack
    self:registerModule("back", getReaderModule("readerback"):new{
        ui = self,
        view = self.view,
    })
    -- fulltext search
    self:registerModule("search", getReaderModule("readersearch"):new{
        dialog = self.dialog,
        view = self.view,
        ui = self
    })
    -- book status
    self:registerModule("status", getReaderModule("readerstatus"):new{
        ui = self,
        document = self.document,
    })
    -- thumbnails service (book map, page browser)
    self:registerModule("thumbnail", getReaderModule("readerthumbnail"):new{
        ui = self,
        document = self.document,
    })
    if not lazyReaderSidePanels() then
        -- file searcher
        self:registerModule("filesearcher", getFileManagerFileSearcher():new{
            dialog = self.dialog,
            ui = self,
        })
        -- folder shortcuts
        self:registerModule("folder_shortcuts", getFileManagerShortcuts():new{
            dialog = self.dialog,
            ui = self,
        })
    end
    if lazyReaderSidePanels() then
        self:registerModule("history", ReaderSidePanelProxy:new{
            target_name = "history",
            target_loader = getFileManagerHistory,
            dialog = self.dialog,
            ui = self,
        })
        self:registerModule("collections", ReaderSidePanelProxy:new{
            target_name = "collections",
            target_loader = getFileManagerCollection,
            dialog = self.dialog,
            ui = self,
        })
    else
        -- history view
        self:registerModule("history", getFileManagerHistory():new{
            dialog = self.dialog,
            ui = self,
        })
        -- collections/favorites view
        self:registerModule("collections", getFileManagerCollection():new{
            dialog = self.dialog,
            ui = self,
        })
    end
    -- book info
    self:registerModule("bookinfo", getFileManagerBookInfo():new{
        dialog = self.dialog,
        document = self.document,
        ui = self,
    })
    -- event listener to change device settings
    self:registerModule("devicelistener", DeviceListener:new {
        document = self.document,
        view = self.view,
        ui = self,
    })
    if not G_reader_settings:isTrue("libra2_disable_reader_networklistener") then
        self:registerModule("networklistener", getNetworkListener():new {
            document = self.document,
            view = self.view,
            ui = self,
        })
    end

    -- koreader plugins
    for _, plugin_module in ipairs(PluginLoader:loadPlugins()) do
        local ok, plugin_or_err = PluginLoader:createPluginInstance(
            plugin_module,
            {
                dialog = self.dialog,
                view = self.view,
                ui = self,
                document = self.document,
            })
        if ok then
            self:registerModule(plugin_module.name, plugin_or_err)
            logger.dbg("RD loaded plugin", plugin_module.name,
                        "at", plugin_module.path)
        end
    end

    -- Allow others to change settings based on external factors
    -- Must be called after plugins are loaded & before setting are read.
    self:handleEvent(Event:new("DocSettingsLoad", self.doc_settings, self.document))
    -- we only read settings after all the widgets are initialized
    self:handleEvent(Event:new("ReadSettings", self.doc_settings))

    for _,v in ipairs(self.postInitCallback) do
        v()
    end
    self.postInitCallback = nil

    -- Now that document is loaded, store book metadata in settings.
    local props = self.document:getProps()
    self.doc_settings:saveSetting("doc_props", props)
    -- And have an extended and customized copy in memory for quick access.
    self.doc_props = getFileManagerBookInfo().extendProps(props, self.document.file)

    local md5 = self.doc_settings:readSetting("partial_md5_checksum")
    if md5 == nil then
        md5 = util.partialMD5(self.document.file)
        self.doc_settings:saveSetting("partial_md5_checksum", md5)
    end

    local summary = self.doc_settings:readSetting("summary", {})
    if getBookList().getBookStatusString(summary.status) == nil then
        summary.status = "reading"
        summary.modified = os.date("%Y-%m-%d", os.time())
    end

    if summary.status ~= "complete" or not G_reader_settings:isTrue("history_freeze_finished_books") then
        require("readhistory"):addItem(self.document.file) -- (will update "lastfile")
    end

    -- After initialisation notify that document is loaded and rendered
    -- CREngine only reports correct page count after rendering is done
    -- Need the same event for PDF document
    self:handleEvent(Event:new("ReaderReady", self.doc_settings))
    self.doc_settings:saveSetting("doc_pages", self.document:getPageCount())

    for _,v in ipairs(self.postReaderReadyCallback) do
        v()
    end
    self.postReaderReadyCallback = nil
    self.reloading = nil
    if self.after_open_callback then
        self:after_open_callback()
        self.after_open_callback = nil
    end

    getBookList().setBookInfoCache(self.document.file, self.doc_settings)

    Device:setIgnoreInput(false) -- Allow processing of events (on Android).
    Input:inhibitInputUntil(0.2)

    -- print("Ordered registered gestures:")
    -- for _, tzone in ipairs(self._ordered_touch_zones) do
    --     print("  "..tzone.def.id)
    -- end

    if ReaderUI.instance == nil then
        logger.dbg("Spinning up new ReaderUI instance", tostring(self))
    else
        -- Should never happen, given what we did in (do)showReader...
        logger.err("ReaderUI instance mismatch! Opened", tostring(self), "while we still have an existing instance:", tostring(ReaderUI.instance), debug.traceback())
    end
    ReaderUI.instance = self
end

function ReaderUI:registerKeyEvents()
    if Device:hasKeys() then
        self.key_events.Home = { { "Home" } }
        self.key_events.Reload = { { "F5" } }
        if Device:hasDPad() and Device:useDPadAsActionKeys() then
            self.key_events.StartHighlightIndicator = { { { "Up", "Down" } } }
        end
        if Device:hasScreenKB() or Device:hasSymKey() then
            if Device:hasKeyboard() then
                self.key_events.ToggleWifi = { { "Shift", "Home" } }
                self.key_events.OpenLastDoc = { { "Shift", "Back" } }
            else -- Currently exclusively targets Kindle 4.
                self.key_events.ToggleWifi = { { "ScreenKB", "Home" } }
                self.key_events.OpenLastDoc = { { "ScreenKB", "Back" } }
            end
        end
    end
end

ReaderUI.onPhysicalKeyboardConnected = ReaderUI.registerKeyEvents

function ReaderUI:setLastDirForFileBrowser(dir)
    if dir and #dir > 1 and dir:sub(-1) == "/" then
        dir = dir:sub(1, -2)
    end
    self.last_dir_for_file_browser = dir
end

function ReaderUI:getLastDirFile(to_file_browser)
    if to_file_browser and self.last_dir_for_file_browser then
        local dir = self.last_dir_for_file_browser
        self.last_dir_for_file_browser = nil
        return dir
    end
    local QuickStart = require("ui/quickstart")
    local last_dir
    local last_file = G_reader_settings:readSetting("lastfile")
    -- ignore quickstart guide as last_file so we can go back to home dir
    if last_file and last_file ~= QuickStart.quickstart_filename then
        last_dir = last_file:match("(.*)/")
    end
    return last_dir, last_file
end

function ReaderUI:showFileManager(file, selected_files)
    local last_dir, last_file
    if file then
        last_dir = util.splitFilePathName(file)
        last_file = file
    else
        last_dir, last_file = self:getLastDirFile(true)
    end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance.file_chooser:changeToPath(last_dir, last_file)
        FileManager.instance.selected_files = selected_files
    else
        FileManager:showFiles(last_dir, last_file, selected_files)
    end
end

function ReaderUI:onShowingReader()
    -- Allows us to optimize out a few useless refreshes in various CloseWidgets handlers...
    self.tearing_down = true
    self.dithered = nil

    -- Don't enforce a "full" refresh, leave that decision to the next widget we'll *show*.
    self:onClose(false)
end

-- Same as above, except we don't close it yet. Useful for plugins that need to close custom Menus before calling showReader.
function ReaderUI:onSetupShowReader()
    self.tearing_down = true
    self.dithered = nil
end

--- @note: Will sanely close existing FileManager/ReaderUI instance for you!
---        This is the *only* safe way to instantiate a new ReaderUI instance!
---        (i.e., don't look at the testsuite, which resorts to all kinds of nasty hacks).
function ReaderUI:showReader(file, provider, seamless, is_provider_forced, after_open_callback)
    logger.dbg("show reader ui")

    if lfs.attributes(file, "mode") ~= "file" then
        UIManager:show(getInfoMessage():new{
             text = T(_("File '%1' does not exist."), BD.filepath(filemanagerutil.abbreviate(file)))
        })
        return
    end

    if provider == nil and DocumentRegistry:hasProvider(file) then
        provider = DocumentRegistry:getProvider(file)
    end
    if provider ~= nil then
        provider = self:extendProvider(file, provider, is_provider_forced)
    end
    if provider and provider.provider then
        self.after_open_callback = after_open_callback
        -- We can now signal the existing ReaderUI/FileManager instances that it's time to go bye-bye...
        UIManager:broadcastEvent(Event:new("ShowingReader"))
        self:showReaderCoroutine(file, provider, seamless)
    else
        UIManager:show(getInfoMessage():new{
            text = T(_("File '%1' is not supported."), BD.filepath(filemanagerutil.abbreviate(file)))
        })
        self:showFileManager(file)
    end
end

function ReaderUI:extendProvider(file, provider, is_provider_forced)
    -- If file extension is single "zip", check the archive content and choose the appropriate provider,
    -- except when the provider choice is forced in the "Open with" dialog.
    -- Also pass to crengine is_fb2 property, based on the archive content (single "zip" extension),
    -- or on the original file double extension ("fb2.zip" etc).
    local _, file_type = filemanagerutil.splitFileNameType(file) -- supports double-extension
    if file_type == "zip" then
        local arc = Archiver.Reader:new()
        if arc:open(file) then
            for entry in arc:iterate() do
                local ext = util.getFileNameSuffix(entry.path)
                if ext and entry.mode == "file" and entry.size > 0 then
                    file_type = ext:lower()
                    break
                end
            end
            arc:close()
        end
        if not is_provider_forced then
            local providers = DocumentRegistry:getProviders("dummy." .. file_type)
            if providers then
                for _, p in ipairs(providers) do
                    if p.provider.provider == "crengine" or p.provider.provider == "mupdf" then -- only these can unzip
                        provider = p.provider
                        break
                    end
                end
            end
        end
    end
    provider.is_fb2 = file_type:sub(1, 2) == "fb"
    provider.is_txt = file_type == "txt"
    return provider
end

function ReaderUI:showReaderCoroutine(file, provider, seamless)
    UIManager:show(getInfoMessage():new{
        text = T(_("Opening file '%1'."), BD.filepath(filemanagerutil.abbreviate(file))),
        timeout = 0.0,
        invisible = seamless,
    })
    -- doShowReader might block for a long time, so force repaint here
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        logger.dbg("creating coroutine for showing reader")
        local co = coroutine.create(function()
            self:doShowReader(file, provider, seamless)
        end)
        local ok, err = coroutine.resume(co)
        if err ~= nil or ok == false then
            io.stderr:write('[!] doShowReader coroutine crashed:\n')
            io.stderr:write(debug.traceback(co, err, 1))
            -- Restore input if we crashed before ReaderUI has restored it
            Device:setIgnoreInput(false)
            Input:inhibitInputUntil(0.2)
            UIManager:show(getInfoMessage():new{
                text = _("No reader engine for this file or invalid file.")
            })
            self:showFileManager(file)
        end
    end)
end

function ReaderUI:doShowReader(file, provider, seamless)
    if seamless then
        UIManager:avoidFlashOnNextRepaint()
    end
    logger.info("opening file", file)
    -- Only keep a single instance running
    if ReaderUI.instance then
        logger.warn("ReaderUI instance mismatch! Tried to spin up a new instance, while we still have an existing one:", tostring(ReaderUI.instance))
        ReaderUI.instance:onClose()
    end
    local document = DocumentRegistry:openDocument(file, provider)
    if not document then
        UIManager:show(getInfoMessage():new{
            text = _("No reader engine for this file or invalid file.")
        })
        self:showFileManager(file)
        return
    end
    if document.is_locked then
        logger.info("document is locked")
        self._coroutine = coroutine.running() or self._coroutine
        self:unlockDocumentWithPassword(document)
        if coroutine.running() then
            local unlock_success = coroutine.yield()
            if not unlock_success then
                self:showFileManager(file)
                return
            end
        end
    end
    local reader = ReaderUI:new{
        dimen = Screen:getSize(),
        covers_fullscreen = true, -- hint for UIManager:_repaint()
        document = document,
        reloading = self.reloading,
        after_open_callback = self.after_open_callback,
    }
    self.reloading = nil
    self.after_open_callback = nil

    Screen:setWindowTitle(reader.doc_props.display_title)
    Device:notifyBookState(reader.doc_props.display_title, document)

    -- This is mostly for the few callers that bypass the coroutine shenanigans and call doShowReader directly,
    -- instead of showReader...
    -- Otherwise, showReader will have taken care of that *before* instantiating a new RD,
    -- in order to ensure a sane ordering of plugins teardown -> instantiation.
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onClose()
    end

    UIManager:show(reader, seamless and "ui" or "full")
end

function ReaderUI:unlockDocumentWithPassword(document, try_again)
    logger.dbg("show input password dialog")
    self.password_dialog = getInputDialog():new{
        title = try_again and _("Password is incorrect, try again?")
            or _("Input document password"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self:closeDialog()
                        coroutine.resume(self._coroutine)
                    end,
                },
                {
                    text = _("OK"),
                    callback = function()
                        local success = self:onVerifyPassword(document)
                        self:closeDialog()
                        if success then
                            coroutine.resume(self._coroutine, success)
                        else
                            self:unlockDocumentWithPassword(document, true)
                        end
                    end,
                },
            },
        },
        text_type = "password",
    }
    UIManager:show(self.password_dialog)
    self.password_dialog:onShowKeyboard()
end

function ReaderUI:onVerifyPassword(document)
    local password = self.password_dialog:getInputText()
    return document:unlock(password)
end

function ReaderUI:closeDialog()
    self.password_dialog:onClose()
    UIManager:close(self.password_dialog)
end

function ReaderUI:onScreenResize(dimen)
    self.dimen = dimen
    self:updateTouchZonesOnScreenResize(dimen)
end

function ReaderUI:saveSettings()
    self:handleEvent(Event:new("SaveSettings"))
    self.doc_settings:flush()
    G_reader_settings:flush()
end

function ReaderUI:onFlushSettings(show_notification)
    self:saveSettings()
    if show_notification then
        -- Invoked from dispatcher to explicitly flush settings
        getNotification():notify(_("Book metadata saved."))
    end
end

function ReaderUI:closeDocument()
    self.document:close()
    self.document = nil
end

function ReaderUI:onClose(full_refresh)
    logger.dbg("closing reader")
    PluginLoader:finalize()
    Device:notifyBookState(nil, nil)
    -- if self.dialog is us, we'll have our onFlushSettings() called
    -- by UIManager:close() below, so avoid double save
    if self.dialog ~= self then
        self:saveSettings()
    end
    local file
    if self.document ~= nil then
        file = self.document.file
        require("readhistory"):updateLastBookTime(self.tearing_down)
        require("readcollection"):updateLastBookTime(file)
        -- Serialize the most recently displayed page for later launch
        DocCache:serialize(file)
        logger.dbg("closing document")
        self:handleEvent(Event:new("CloseDocument"))
        if self.document:isEdited() and not self.highlight.highlight_write_into_pdf then
            self.document:discardChange()
        end
        self:closeDocument()
    end
    UIManager:close(self.dialog, full_refresh ~= false and "full")
    if file then
        getBookList().setBookInfoCacheProperty(file, "percent_finished", self.doc_settings:readSetting("percent_finished"))
        -- other cached properties of the currently opened document are updated in real time
    end
end

function ReaderUI:onCloseWidget()
    if ReaderUI.instance == self then
        logger.dbg("Tearing down ReaderUI", tostring(self))
    else
        logger.warn("ReaderUI instance mismatch! Closed", tostring(self), "while the active one is supposed to be", tostring(ReaderUI.instance))
    end
    ReaderUI.instance = nil
    self._coroutine = nil
end

function ReaderUI:dealWithLoadDocumentFailure()
    -- Sadly, we had to delay loadDocument() to about now, so we only
    -- know now this document is not valid or recognized.
    -- We can't do much more than crash properly here (still better than
    -- going on and segfaulting when calling other methods on unitiliazed
    -- _document)
    -- As we are in a coroutine, we can pause and show an InfoMessage before exiting
    local _coroutine = coroutine.running()
    if coroutine then
        logger.warn("crengine failed recognizing or parsing this file: unsupported or invalid document")
        UIManager:show(getInfoMessage():new{
            text = _("Failed recognizing or parsing this file: unsupported or invalid document.\nKOReader will exit now."),
            dismiss_callback = function()
                coroutine.resume(_coroutine, false)
            end,
        })
        -- Restore input, so can catch the InfoMessage dismiss and exit
        Device:setIgnoreInput(false)
        Input:inhibitInputUntil(0.2)
        coroutine.yield() -- pause till InfoMessage is dismissed
    end
    -- We have to error and exit the coroutine anyway to avoid any segfault
    error("crengine failed recognizing or parsing this file: unsupported or invalid document")
end

function ReaderUI:onHome()
    local file = self.document.file
    self:onClose()
    self:showFileManager(file)
    return true
end

function ReaderUI:onReload()
    self:reloadDocument()
end

function ReaderUI:reloadDocument(after_close_callback, seamless, after_open_callback)
    local file = self.document.file
    local provider = getmetatable(self.document).__index

    -- Mimic onShowingReader's refresh optimizations
    self.tearing_down = true
    self.dithered = nil

    self:handleEvent(Event:new("CloseReaderMenu"))
    self:handleEvent(Event:new("CloseConfigMenu"))
    self:handleEvent(Event:new("PreserveCurrentSession")) -- don't reset statistics' start_current_period
    self.highlight:onClose() -- close highlight dialog if any
    self:onClose(false)
    if after_close_callback then
        -- allow caller to do stuff between close an re-open
        after_close_callback(file, provider)
    end

    self.reloading = true
    self:showReader(file, provider, seamless, nil, after_open_callback)
end

function ReaderUI:switchDocument(new_file, seamless, after_open_callback)
    if not new_file then return end

    -- Mimic onShowingReader's refresh optimizations
    self.tearing_down = true
    self.dithered = nil

    self:handleEvent(Event:new("CloseReaderMenu"))
    self:handleEvent(Event:new("CloseConfigMenu"))
    self.highlight:onClose() -- close highlight dialog if any
    self:onClose(false)

    self:showReader(new_file, nil, seamless, nil, after_open_callback)
end

function ReaderUI:onOpenLastDoc()
    self:switchDocument(self.menu:getPreviousFile())
end

function ReaderUI:onAnnotationsModified()
    getBookList().setBookInfoCacheProperty(self.document.file, "has_annotations", self.annotation:hasAnnotations())
end

function ReaderUI:onDocumentRerendered()
    local pages = self.document:getPageCount()
    self.doc_settings:saveSetting("doc_pages", pages)
    if self.doc_settings:nilOrFalse("pagemap_use_page_labels") then
        getBookList().setBookInfoCacheProperty(self.document.file, "pages", pages)
    end
end

function ReaderUI:onUsePageLabelsUpdated()
    local pages = self.doc_settings:isTrue("pagemap_use_page_labels")
        and self.doc_settings:readSetting("pagemap_doc_pages")
         or self.doc_settings:readSetting("doc_pages")
        getBookList().setBookInfoCacheProperty(self.document.file, "pages", pages)
end

function ReaderUI:getCurrentPage()
    return self.paging and self.paging.current_page or self.document:getCurrentPage()
end

return ReaderUI
