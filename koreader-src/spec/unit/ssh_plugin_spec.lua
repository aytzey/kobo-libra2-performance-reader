describe("SSH plugin watchdog", function()
    local PID_PATH = "/tmp/dropbear_koreader.pid"
    local SSH
    local UIManager
    local util

    local function write_pid(pid)
        local file = assert(io.open(PID_PATH, "w"))
        file:write(tostring(pid), "\n")
        file:close()
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        UIManager = require("ui/uimanager")
        util = require("util")
    end)

    before_each(function()
        os.remove(PID_PATH)
        stub(util, "pathExists")
        util.pathExists.invokes(function(path)
            if path == "dropbear" then
                return true
            end
            if path == PID_PATH then
                local file = io.open(PID_PATH, "r")
                if file then
                    file:close()
                    return true
                end
                return false
            end
            if path == "/proc/999999" then
                return false
            end
            return false
        end)
        SSH = dofile("plugins/SSH.koplugin/main.lua")
    end)

    after_each(function()
        os.remove(PID_PATH)
        util.pathExists:revert()
        if type(UIManager.scheduleIn) == "table" and UIManager.scheduleIn.revert then
            UIManager.scheduleIn:revert()
        end
    end)

    it("does not treat a stale dropbear pid file as a running server", function()
        write_pid(999999)

        assert.is_false(SSH:isRunning())
        assert.is_nil(io.open(PID_PATH, "r"))
    end)

    it("starts dropbear with keepalive and idle-timeout protection", function()
        local command = SSH:_dropbearCommand(true)

        assert.truthy(command:find("-K 30", 1, true))
        assert.truthy(command:find("-I 0", 1, true))
        assert.truthy(command:find("-P " .. PID_PATH, 1, true))
    end)

    it("restarts silently when watchdog sees autostart SSH is down", function()
        local widget = setmetatable({
            autostart = true,
            ssh_should_run = true,
            start = mock(function() end),
        }, { __index = SSH })

        widget:_ensureRunning("unit test")

        assert.stub(widget.start).was.called(1)
        assert.stub(widget.start).was.called_with(widget, true)
    end)

    it("checks SSH shortly after resume", function()
        local scheduled
        stub(UIManager, "scheduleIn")
        UIManager.scheduleIn.invokes(function(_, _, callback)
            scheduled = callback
        end)
        local widget = setmetatable({
            autostart = true,
            ssh_should_run = true,
            start = mock(function() end),
        }, { __index = SSH })

        widget:onResume()
        assert.is_function(scheduled)
        scheduled()

        assert.stub(widget.start).was.called(1)
        assert.stub(widget.start).was.called_with(widget, true)
    end)
end)
