require "TimedActions/ISReadABook"
require "CustomMagazines/CustomMagazinesCore"

ISReadCustomMagazine = ISReadABook:derive("ISReadCustomMagazine")
CustomMagazinesReaderPause = CustomMagazinesReaderPause or { readers = 0, ownsPause = false, multiplier = 1, speed = 1 }

local function isMultiplayerClient()
    return isClient and isClient()
end

function ISReadCustomMagazine:acquireReaderPause()
    if self.pauseAcquired or isMultiplayerClient() then return end
    local state = CustomMagazinesReaderPause
    if state.readers == 0 then
        state.speed = getGameSpeed()
        state.ownsPause = state.speed ~= 0
        if state.ownsPause then
            local ok, multiplier = pcall(function() return getGameTime():getMultiplier() end)
            state.multiplier = ok and tonumber(multiplier) and multiplier > 0 and multiplier or 1
            if type(setGameSpeed) == "function" then
                local pauseOk = pcall(setGameSpeed, 0)
                if not pauseOk then state.ownsPause = false end
            else
                state.ownsPause = false
            end
        end
    end
    state.readers = state.readers + 1
    self.pauseAcquired = true
end

function ISReadCustomMagazine:releaseReaderPause()
    if not self.pauseAcquired then return end
    self.pauseAcquired = false
    local state = CustomMagazinesReaderPause
    state.readers = math.max(0, (tonumber(state.readers) or 1) - 1)
    if state.readers == 0 then
        if state.ownsPause and getGameSpeed() == 0 then
            pcall(setGameSpeed, state.speed or 1)
            pcall(function() getGameTime():setMultiplier(state.multiplier or 1) end)
        end
        state.ownsPause = false
        state.multiplier = 1
        state.speed = 1
    end
end

function ISReadCustomMagazine:abortReaderSession()
    if self.sessionClosed then return end
    self.sessionClosed = true
    if isMultiplayerClient() then
        sendClientCommand(self.character, "CustomMagazines", "abortRead", {
            itemId = self.item:getID(), sessionId = self.sessionId,
        })
    elseif CustomMagazinesServer then
        CustomMagazinesServer.abortRead(self.character, self.item:getID(), self.sessionId)
    end
end

function ISReadCustomMagazine:recordPageViewed(page)
    page = tonumber(page)
    if not page or page ~= math.floor(page) or page < 1 or page > #self.files then return false end
    local accepted
    if isMultiplayerClient() then
        sendClientCommand(self.character, "CustomMagazines", "pageViewed", {
            itemId = self.item:getID(), sessionId = self.sessionId, page = page,
        })
        accepted = true
    else
        accepted = CustomMagazinesServer and CustomMagazinesServer.recordReadPage(
            self.character, self.item:getID(), self.sessionId, page
        ) or false
    end
    if not accepted then return false end
    if not self.viewedPages[page] then
        self.viewedPages[page] = true
        self.viewedCount = self.viewedCount + 1
    end
    return true
end

function ISReadCustomMagazine:onReaderClosed()
    self:releaseReaderPause()
    if self.sessionClosed then return end
    local complete = #self.files > 0 and self.viewedCount >= #self.files
    if complete then
        self.sessionClosed = true
        if isMultiplayerClient() then
            sendClientCommand(self.character, "CustomMagazines", "completeRead", {
                itemId = self.item:getID(), sessionId = self.sessionId,
            })
        elseif CustomMagazinesServer then
            local ok, _, folderId = CustomMagazinesServer.completeRead(
                self.character, self.item:getID(), self.sessionId
            )
            if ok and CustomMagazinesClient then
                CustomMagazinesClient.readFolders[tostring(folderId)] = true
            end
        else
            self.sessionClosed = false
            self:abortReaderSession()
        end
    else
        self:abortReaderSession()
        self.item:setAlreadyReadPages(0)
    end
    self:forceStop()
end

function ISReadCustomMagazine:new(character, item, folderId, title, files, root, sessionId)
    local o = ISReadABook.new(self, character, item)
    o.folderId = folderId
    o.title = title
    o.files = files or {}
    o.imageRoot = root
    o.sessionId = sessionId
    o.reader = nil
    o.viewedPages = {}
    o.viewedCount = 0
    o.sessionClosed = false
    o.pauseAcquired = false
    return o
end

function ISReadCustomMagazine:getDuration()
    -- Reading is driven by browsing the pages; the UI closes the indefinite action.
    return -1
end

function ISReadCustomMagazine:update()
    self.item:setJobDelta(0.0)
end

function ISReadCustomMagazine:start()
    ISReadABook.start(self)
    if not CustomMagazinesReaderUI then
        self:forceStop()
        return
    end
    self.reader = CustomMagazinesReaderUI:new(
        self.character:getPlayerNum(), self.item, self.folderId,
        self.title, self.files, self.imageRoot, self
    )
    self.reader:initialise()
    self.reader:instantiate()
    self.reader:addToUIManager()
    self.reader:centerOnScreen(self.character:getPlayerNum())
    self:acquireReaderPause()
    self.reader:setPage(1)
end

function ISReadCustomMagazine:stop()
    if not self.sessionClosed then self:abortReaderSession() end
    if self.reader then
        self.reader.actionStopped = true
        self.reader:close()
    end
    self:releaseReaderPause()
    ISReadABook.stop(self)
end

function ISReadCustomMagazine:perform()
    if not self.sessionClosed then self:abortReaderSession() end
    if self.reader then
        self.reader.actionStopped = true
        self.reader:close()
    end
    self:releaseReaderPause()
    self.character:setReading(false)
    self.item:setJobDelta(0.0)
    ISBaseTimedAction.perform(self)
end
