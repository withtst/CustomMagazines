require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "CustomMagazines/CustomMagazinesCore"

CustomMagazinesReaderUI = ISCollapsableWindow:derive("CustomMagazinesReaderUI")

function CustomMagazinesReaderUI:new(playerNum, item, folderId, title, files, root, action)
    local width, height = 300, 260
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.item = item
    o.folderId = folderId
    o.title = title or item:getName()
    o.files = files or {}
    o.imageRoot = root
    o.action = action
    o.pageIndex = 1
    o.pageDisplayWidth = 260
    o.pageDisplayHeight = 160
    o.pageTexture = nil
    o.textureOwner = tostring(playerNum) .. ":" .. tostring(item:getID())
    o.closed = false
    o.actionCompleted = false
    o.actionStopped = false
    o.background = true
    o.backgroundColor = { r = 0.08, g = 0.07, b = 0.06, a = 0.96 }
    o.resizable = false
    o.drawFrame = true
    o:setWantKeyEvents(true)
    o:setTitle(o.title)
    return o
end

function CustomMagazinesReaderUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local buttonHeight = 28
    self.previousButton = ISButton:new(16, 0, 100, buttonHeight, getText("UI_CustomMagazines_Previous"), self, CustomMagazinesReaderUI.onPrevious)
    self.previousButton:initialise()
    self.previousButton:instantiate()
    self:addChild(self.previousButton)

    self.nextButton = ISButton:new(0, 0, 100, buttonHeight, getText("UI_CustomMagazines_Next"), self, CustomMagazinesReaderUI.onNext)
    self.nextButton:initialise()
    self.nextButton:instantiate()
    self:addChild(self.nextButton)
    self:layoutControls()
end

function CustomMagazinesReaderUI:layoutControls()
    if not self.previousButton or not self.nextButton then return end
    local buttonHeight = 28
    local buttonWidth = math.min(130, math.max(60, math.floor((self.width - 104) / 2)))
    local buttonY = self.height - buttonHeight - 12
    self.previousButton:setWidth(buttonWidth)
    self.previousButton:setHeight(buttonHeight)
    self.previousButton:setX(16)
    self.previousButton:setY(buttonY)
    self.nextButton:setWidth(buttonWidth)
    self.nextButton:setHeight(buttonHeight)
    self.nextButton:setX(self.width - buttonWidth - 16)
    self.nextButton:setY(buttonY)
end

function CustomMagazinesReaderUI:resizeToPage(texture)
    if not texture then return end
    local screenWidth = getCore():getScreenWidth()
    local screenHeight = getCore():getScreenHeight()
    self.lastScreenWidth = screenWidth
    self.lastScreenHeight = screenHeight
    self.pageDisplayWidth, self.pageDisplayHeight = CustomMagazines.pageDisplaySize(
        texture:getWidth(), texture:getHeight(), screenWidth, screenHeight
    )

    local titleBarHeight = self:titleBarHeight()
    self:setWidth(math.max(self.pageDisplayWidth + 32, 260))
    self:setHeight(titleBarHeight + self.pageDisplayHeight + 68)
    self:setX((screenWidth - self.width) / 2)
    self:setY((screenHeight - self.height) / 2)
    self:layoutControls()
end

function CustomMagazinesReaderUI:onPrevious()
    if #self.files == 0 then return end
    self:setPage(self.pageIndex > 1 and self.pageIndex - 1 or #self.files)
end

function CustomMagazinesReaderUI:onNext()
    if #self.files == 0 then return end
    self:setPage(self.pageIndex < #self.files and self.pageIndex + 1 or 1)
end

function CustomMagazinesReaderUI:isKeyConsumed(key)
    return not self.closed and key == Keyboard.KEY_ESCAPE
end

function CustomMagazinesReaderUI:onKeyRelease(key)
    if not self.closed and self:isVisible() and key == Keyboard.KEY_ESCAPE then self:close() end
end

function CustomMagazinesReaderUI:setPage(index)
    if self.closed or #self.files == 0 then return end
    index = math.max(1, math.min(#self.files, tonumber(index) or 1))
    self.pageIndex = index
    CustomMagazines.releaseTexture(self.textureOwner)
    self.pageTexture = CustomMagazines.loadTexture(self.imageRoot, self.folderId, self.files[index], self.textureOwner)
    self.previousButton:setEnable(true)
    self.nextButton:setEnable(true)
    self.previousButton:setTitle(getText(index == 1 and "UI_CustomMagazines_LastPage" or "UI_CustomMagazines_Previous"))
    self.nextButton:setTitle(getText(index == #self.files and "UI_CustomMagazines_FirstPage" or "UI_CustomMagazines_Next"))
    if self.pageTexture then
        self:resizeToPage(self.pageTexture)
        if self.action then self.action:recordPageViewed(index) end
    elseif self.action and not self.actionStopped then
        self.action:releaseReaderPause()
        self.action:forceStop()
    end
end

function CustomMagazinesReaderUI:render()
    if self.pageTexture then
        local screenWidth = getCore():getScreenWidth()
        local screenHeight = getCore():getScreenHeight()
        if screenWidth ~= self.lastScreenWidth or screenHeight ~= self.lastScreenHeight then
            self:resizeToPage(self.pageTexture)
        end
    end
    ISCollapsableWindow.render(self)
    local imageX = (self.width - self.pageDisplayWidth) / 2
    local imageY = self:titleBarHeight() + 12
    if self.pageTexture then
        self:drawTextureScaledAspect(self.pageTexture, imageX, imageY, self.pageDisplayWidth, self.pageDisplayHeight, 1, 1, 1, 1)
    else
        self:drawTextCentre(getText("UI_CustomMagazines_ImageUnavailable"), self.width / 2, imageY + self.pageDisplayHeight / 2, 1, 0.6, 0.6, 1, UIFont.Medium)
    end
    self:drawTextCentre(getText("UI_CustomMagazines_Page", self.pageIndex, #self.files), self.width / 2, self.height - 43, 1, 1, 1, 1, UIFont.Small)
end

function CustomMagazinesReaderUI:close()
    if self.closed then return end
    self.closed = true
    if self.action and not self.actionStopped and not self.action.sessionClosed then
        self.action:onReaderClosed()
    end
    CustomMagazines.releaseTexture(self.textureOwner)
    self.pageTexture = nil
    self:removeFromUIManager()
end
