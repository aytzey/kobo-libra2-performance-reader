local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local MassStorage = {}

local function processRunning(pattern)
    local handle = io.popen("pgrep -f " .. pattern .. " 2>/dev/null | head -n 1")
    if not handle then
        return false
    end
    local pid = handle:read("*l")
    handle:close()
    return pid ~= nil and pid ~= ""
end

local function waitForProcessExit(pattern, attempts)
    for _ = 1, attempts do
        if not processRunning(pattern) then
            return true
        end
        os.execute("usleep 100000")
    end
    return not processRunning(pattern)
end

function MassStorage:cleanupBlockingProcesses()
    logger.info("Preparing USBMS: stopping background processes that may keep onboard storage busy")
    UIManager:broadcastEvent(Event:new("PrepareUSBMS"))
    UIManager:flushSettings()
    os.execute("sync")
    self:stopUsbNetworkForStorage()

    os.execute("killall -q -TERM ttsreader-play 2>/dev/null || true")
    os.execute("pkill -TERM -f '/ttsreader-play' 2>/dev/null || true")
    waitForProcessExit("'[t]tsreader-play'", 10)
    if processRunning("'[t]tsreader-play'") then
        os.execute("killall -q -KILL ttsreader-play 2>/dev/null || true")
        os.execute("pkill -KILL -f '/ttsreader-play' 2>/dev/null || true")
    end

    os.execute("if [ -f /tmp/dropbear_koreader.pid ]; then kill -TERM $(cat /tmp/dropbear_koreader.pid) 2>/dev/null || true; fi")
    os.execute("killall -q -TERM dropbear 2>/dev/null || true")
    waitForProcessExit("'[d]ropbear'", 10)
    if processRunning("'[d]ropbear'") then
        os.execute("killall -q -KILL dropbear 2>/dev/null || true")
    end
    os.remove("/tmp/dropbear_koreader.pid")
    os.execute("sync")
end

-- if required a popup will ask before entering mass storage mode
function MassStorage:requireConfirmation()
    return not G_reader_settings:isTrue("mass_storage_confirmation_disabled")
end

function MassStorage:isEnabled()
    return not G_reader_settings:isTrue("mass_storage_disabled")
end

function MassStorage:canUsbNetwork()
    if not Device:isKobo() then
        return false
    end
    local file = io.open("./usb-network-ssh.sh", "r")
    if file then
        file:close()
        return true
    end
    return false
end

function MassStorage:isUsbNetworkRunning()
    return os.execute("sh ./usb-network-ssh.sh status >/dev/null 2>&1") == 0
end

function MassStorage:_sshPort()
    return tostring(G_reader_settings:readSetting("SSH_port") or "2222")
end

function MassStorage:_usbNetworkCommand(action)
    local port = self:_sshPort():gsub("[^0-9]", "")
    if port == "" then
        port = "2222"
    end
    return string.format(
        "KOBO_USB_SSH_PORT=%s sh ./usb-network-ssh.sh %s >/tmp/kobo-usb-network-ssh.log 2>&1",
        port,
        action)
end

function MassStorage:startUsbNetwork()
    if not self:canUsbNetwork() then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("USB network mode is not available on this device."),
        })
        return
    end

    logger.info("Starting USB cable SSH network")
    local ok = os.execute(self:_usbNetworkCommand("recover")) == 0
    if ok then
        UIManager:show(InfoMessage:new{
            timeout = 18,
            text = T(_("USB cable SSH is ready.\n\nAddress: %1\nSSH: ssh root@%1 -p %2\n\nIf your computer does not get an address automatically, set its USB network interface to %3/24."),
                "192.168.2.2",
                self:_sshPort(),
                "192.168.2.1"),
        })
    else
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            timeout = 12,
            text = _("USB cable SSH could not start. Check /tmp/kobo-usb-network-ssh.log on the device."),
        })
    end
end

function MassStorage:_stopUsbNetworkQuiet()
    if not self:canUsbNetwork() then
        return false
    end

    local was_running = self:isUsbNetworkRunning()
    -- The stop script is intentionally idempotent; run it even when status is
    -- false so stale DHCP helpers, pid files, or a half-removed g_ether gadget
    -- cannot block the next USB mass-storage session.
    os.execute(self:_usbNetworkCommand("stop"))
    waitForProcessExit("'[k]obo-usb-dhcpd'", 10)
    waitForProcessExit("'[u]dhcpd'", 10)
    os.execute("rmmod g_ether 2>/dev/null || true")
    return was_running
end

function MassStorage:stopUsbNetworkForStorage()
    if self:_stopUsbNetworkQuiet() then
        logger.info("Preparing USBMS: stopped USB cable SSH network gadget")
    end
end

function MassStorage:stopUsbNetwork()
    logger.info("Stopping USB cable SSH network")
    self:_stopUsbNetworkQuiet()
    UIManager:show(InfoMessage:new{
        timeout = 3,
        text = _("USB cable SSH stopped."),
    })
end

-- mass storage settings menu
function MassStorage:getSettingsMenuTable()
    return {
        {
            text = _("Disable confirmation popup"),
            help_text = _([[This will ONLY affect what happens when you plug in the device!]]),
            checked_func = function() return not self:requireConfirmation() end,
            callback = function()
                G_reader_settings:saveSetting("mass_storage_confirmation_disabled", self:requireConfirmation())
            end,
        },
        {
            text = _("Disable mass storage functionality"),
            help_text = _([[In case your device uses an unsupported setup where you know it won't work properly.]]),
            checked_func = function() return not self:isEnabled() end,
            callback = function()
                G_reader_settings:saveSetting("mass_storage_disabled", self:isEnabled())
            end,
        },
    }
end

-- mass storage actions
function MassStorage:getActionsMenuTable()
    return {
        text = _("USB connection"),
        enabled_func = function() return self:isEnabled() or self:canUsbNetwork() end,
        sub_item_table = {
            {
                text = _("Start USB storage"),
                enabled_func = function() return self:isEnabled() end,
                callback = function()
                    self:startStorage()
                end,
            },
            {
                text = _("Start USB cable SSH"),
                enabled_func = function() return self:canUsbNetwork() end,
                callback = function()
                    self:startUsbNetwork()
                end,
            },
            {
                text = _("Stop USB cable SSH"),
                enabled_func = function() return self:canUsbNetwork() and self:isUsbNetworkRunning() end,
                callback = function()
                    self:stopUsbNetwork()
                end,
            },
        },
    }
end

function MassStorage:startStorage()
    if not Device:canToggleMassStorage() or not self:isEnabled() then
        return
    end
    -- save settings before activating USBMS:
    self:cleanupBlockingProcesses()
    logger.info("Exiting KOReader to enter USBMS mode...")
    UIManager:broadcastEvent(Event:new("Close"))
    UIManager:quit(86)
end

function MassStorage:showConnectionDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local buttons = {}
    if self:canUsbNetwork() then
        if self:isUsbNetworkRunning() then
            buttons[#buttons + 1] = {
                {
                    text = _("Stop USB cable SSH"),
                    callback = function()
                        UIManager:close(self.usb_connection_widget)
                        self.usb_connection_widget = nil
                        self:stopUsbNetwork()
                    end,
                },
            }
        else
            buttons[#buttons + 1] = {
                {
                    text = _("USB cable SSH"),
                    callback = function()
                        UIManager:close(self.usb_connection_widget)
                        self.usb_connection_widget = nil
                        self:startUsbNetwork()
                    end,
                },
            }
        end
    end
    if self:isEnabled() then
        buttons[#buttons + 1] = {
            {
                text = _("USB storage"),
                callback = function()
                    UIManager:close(self.usb_connection_widget)
                    self.usb_connection_widget = nil
                    self:startStorage()
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function()
                self:dismiss()
            end,
        },
    }

    self.usb_connection_widget = ButtonDialog:new{
        title = _("USB connection\n\nChoose how this cable should connect to the computer."),
        width = math.floor(Device.screen:getWidth() * 0.92),
        buttons = buttons,
    }
    UIManager:show(self.usb_connection_widget)
end

-- exit KOReader and start mass storage mode, or expose a cable SSH link.
function MassStorage:start(with_confirmation)
    if not Device:canToggleMassStorage() then
        return
    end

    if self:canUsbNetwork() then
        self:showConnectionDialog()
        return
    end

    local ask
    if with_confirmation ~= nil then
        ask = with_confirmation
    else
        ask = self:requireConfirmation()
    end

    if ask then
        local ConfirmBox = require("ui/widget/confirmbox")
        self.usbms_widget = ConfirmBox:new{
            text = _("Share storage via USB?"),
            ok_text = _("Share"),
            ok_callback = function()
                self:startStorage()
            end,
            cancel_callback = function()
                self:dismiss()
            end,
        }

        UIManager:show(self.usbms_widget)
    elseif self:isEnabled() then
        self:startStorage()
    end
end

-- Dismiss the ConfirmBox
function MassStorage:dismiss()
    if self.usb_connection_widget then
        UIManager:close(self.usb_connection_widget)
        self.usb_connection_widget = nil
    end
    if self.usbms_widget then
        UIManager:close(self.usbms_widget)
        self.usbms_widget = nil
    end
end

return MassStorage
