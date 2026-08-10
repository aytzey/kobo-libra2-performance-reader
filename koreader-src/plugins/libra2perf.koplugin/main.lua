local Device = require("device")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Tuning = require("tuning")
local _ = require("gettext")
local FileManager
local InfoMessage
local UIManager

local function getFileManager()
    FileManager = FileManager or require("apps/filemanager/filemanager")
    return FileManager
end

local function getInfoMessage()
    InfoMessage = InfoMessage or require("ui/widget/infomessage")
    return InfoMessage
end

local function getUIManager()
    UIManager = UIManager or require("ui/uimanager")
    return UIManager
end

local Libra2Perf = WidgetContainer:extend{
    name = "libra2perf",
    is_doc_only = false,
}

function Libra2Perf:init()
    self.is_libra2 = Tuning.isLibra2(Device)
    if self.is_libra2 then
        self.applied_on_start = Tuning.apply(G_defaults, G_reader_settings, Device.screen, {
            gestures = Tuning.openGestureSettings(),
        })
    end
    self.ui.menu:registerToMainMenu(self)
end

function Libra2Perf:showStatus()
    local text
    if self.is_libra2 then
        local state = G_reader_settings:readSetting(Tuning.profile_key) == Tuning.profile_version
            and _("active")
            or _("not applied")
        text = _("Libra 2 UX/performance profile: ") .. state
            .. _("\n\nPDF/EPUB cache, e-ink refresh, tap zones, gesture latency, highlight flow, link handling, UI flashing, and background plugin load have been tuned for faster opens and page turns.")
    else
        text = _("This performance profile only applies to Kobo Libra 2.")
    end
    getUIManager():show(getInfoMessage():new{ text = text })
end

function Libra2Perf:openBooksFolder()
    local path = "/mnt/onboard/Books"
    if self.ui.document then
        self.ui:onClose()
    end
    local file_manager = getFileManager()
    if file_manager.instance then
        file_manager.instance:reinit(path)
    else
        file_manager:showFiles(path)
    end
end

function Libra2Perf:addToMainMenu(menu_items)
    menu_items.libra2perf = {
        text = _("Libra 2 UX/performance"),
        sorting_hint = "device",
        sub_item_table = {
            {
                text = _("Apply UX/performance profile"),
                enabled_func = function()
                    return self.is_libra2
                end,
                keep_menu_open = true,
                callback = function()
                    Tuning.apply(G_defaults, G_reader_settings, Device.screen, {
                        force = true,
                        gestures = Tuning.openGestureSettings(),
                    })
                    getUIManager():show(getInfoMessage():new{
                        text = _("UX/performance profile applied. Restart KOReader once for plugin load changes to take effect."),
                    })
                end,
            },
            {
                text = _("Open Books folder"),
                enabled_func = function()
                    return self.is_libra2
                end,
                callback = function()
                    self:openBooksFolder()
                end,
            },
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function()
                    self:showStatus()
                end,
            },
        },
    }
end

return Libra2Perf
