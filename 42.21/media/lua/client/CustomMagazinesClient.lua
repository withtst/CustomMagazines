require "CustomMagazines/CustomMagazinesCore"
require "ISUI/ISTextBox"
require "TimedActions/ISReadCustomMagazine"

CustomMagazinesClient = CustomMagazinesClient or {}
local Client = CustomMagazinesClient
Client.titles = Client.titles or {}
Client.aliases = Client.aliases or {}
Client.pendingPlayers = Client.pendingPlayers or {}
Client.readFolders = Client.readFolders or {}

local function listSize(list)
    if not list then return 0 end
    local ok, size = pcall(function() return list:size() end)
    if ok and size then return size end
    return 0
end

local function findItemById(container, itemId, visited)
    if not container or visited[container] then return nil end
    visited[container] = true
    local items = container:getItems()
    for i = 0, listSize(items) - 1 do
        local item = items:get(i)
        if item and item:getID() == itemId then return item end
        if item and instanceof(item, "InventoryContainer") then
            local found = findItemById(item:getInventory(), itemId, visited)
            if found then return found end
        end
    end
    return nil
end

local function resolveLocalId(folderId)
    local id = folderId
    local seen = {}
    while id and Client.aliases[id] and not seen[id] do
        seen[id] = true
        id = Client.aliases[id]
    end
    if not id then
        local state = ModData.getOrCreate(CustomMagazines.StateKey)
        id = folderId
        seen = {}
        while id and state.aliases and state.aliases[id] and not seen[id] do
            seen[id] = true
            id = state.aliases[id]
        end
        if id and state.titles then Client.titles[id] = Client.titles[id] or state.titles[id] end
    end
    return id
end

function Client.titleFor(folderId)
    local id = resolveLocalId(folderId)
    if not id then return nil end
    if Client.titles[id] then return Client.titles[id], id end
    local state = ModData.getOrCreate(CustomMagazines.StateKey)
    local title = state.titles and state.titles[id] or nil
    if title then Client.titles[id] = title end
    return title or CustomMagazines.defaultTitle(id), id
end

function Client.isFolderRead(player, folderId)
    local id = resolveLocalId(folderId) or folderId
    if not id then return false end
    if Client.readFolders[tostring(id)] then return true end
    if player and player.getAlreadyReadPages then
        local ok, pages = pcall(function() return player:getAlreadyReadPages("CustomMagazines:" .. tostring(id)) end)
        if ok and tonumber(pages) and tonumber(pages) > 0 then return true end
    end
    return false
end

function Client.normalizeItem(item, player)
    if not item or item:getFullType() ~= CustomMagazines.ItemFullType then return end
    local data = item:getModData()
    local oldFolderId = data.folderId
    local oldName = item:getName()
    local title, resolvedId = Client.titleFor(data.folderId)
    if resolvedId then data.folderId = resolvedId end
    if title and item:getName() ~= title then item:setName(title) end
    if isClient() and player and (oldFolderId ~= data.folderId or oldName ~= item:getName()) then
        sendClientCommand(player, "CustomMagazines", "normalizeItem", { itemId = item:getID() })
    end
end

local function updateContainer(container, visited)
    if not container or visited[container] then return end
    visited[container] = true
    local items = container:getItems()
    for i = 0, listSize(items) - 1 do
        local item = items:get(i)
        if item then
            Client.normalizeItem(item)
            if instanceof(item, "InventoryContainer") then updateContainer(item:getInventory(), visited) end
        end
    end
end

function Client.updateLoadedWorld()
    local visited = {}
    for playerNum = 0, 3 do
        local player = getSpecificPlayer(playerNum)
        if player then updateContainer(player:getInventory(), visited) end
    end
    local cell = getCell and getCell() or nil
    if not cell then return end
    local minX, maxX = cell:getMinX(), cell:getMaxX()
    local minY, maxY = cell:getMinY(), cell:getMaxY()
    local minZ, maxZ = cell:getMinZ(), cell:getMaxZ()
    local squareCount = 0
    for z = minZ, maxZ do
        for y = minY, maxY do
            for x = minX, maxX do
                squareCount = squareCount + 1
                if squareCount > 1000000 then return end
                local square = cell:getGridSquare(x, y, z)
                if square then
                    local groundItems = square:getWorldObjects()
                    for i = 0, listSize(groundItems) - 1 do
                        local worldItem = groundItems:get(i)
                        if worldItem then Client.normalizeItem(worldItem:getItem()) end
                    end
                    local objects = square:getObjects()
                    for i = 0, listSize(objects) - 1 do
                        local object = objects:get(i)
                        if object and object:getContainerCount() > 0 then
                            updateContainer(object:getContainer(), visited)
                        end
                    end
                end
            end
        end
    end
end

local function showBadText(player, key)
    if player and HaloTextHelper then
        HaloTextHelper.addBadText(player, getText(key))
    end
end

function Client.readErrorKey(reason)
    if reason == "no-supported-pages" then return "UI_CustomMagazines_NoPages" end
    if reason == "magazine-not-in-inventory" then return "UI_CustomMagazines_ItemUnavailable" end
    if reason == "already-reading" then return "UI_CustomMagazines_AlreadyReading" end
    return "UI_CustomMagazines_ReadFailed"
end

local function showReadFailure(player, reason)
    print("CustomMagazines: prepareRead failed: " .. tostring(reason or "unknown"))
    showBadText(player, Client.readErrorKey(reason))
end

local function beginRead(player, item, response)
    if not player or not item then return end
    local root = CustomMagazines.getImageRoot()
    if not root then
        showBadText(player, "UI_CustomMagazines_PathMissing")
        if isClient() then
            sendClientCommand(player, "CustomMagazines", "abortRead", { itemId = response.itemId, sessionId = response.sessionId })
        end
        return
    end
    local files = CustomMagazines.listImages(root, response.folderId)
    if #files ~= tonumber(response.pageCount) or CustomMagazines.folderSignature(files) ~= response.fileSignature then
        showBadText(player, "UI_CustomMagazines_FolderMismatch")
        if isClient() then
            sendClientCommand(player, "CustomMagazines", "abortRead", { itemId = response.itemId, sessionId = response.sessionId })
        elseif CustomMagazinesServer then
            CustomMagazinesServer.abortRead(player, response.itemId, response.sessionId)
        end
        return
    end

    local itemData = item:getModData()
    itemData.folderId = response.folderId
    item:setName(response.title)
    item:setNumberOfPages(tonumber(response.pageCount))
    item:setAlreadyReadPages(0)
    local action = ISReadCustomMagazine:new(player, item, response.folderId, response.title, files, root, response.sessionId)
    ISTimedActionQueue.add(action)
end

function Client.prepareRead(player, item)
    if not player or not item then return end
    Client.normalizeItem(item, player)
    local itemId = item:getID()
    if isClient() then
        Client.pendingPlayers[tostring(itemId)] = player
        sendClientCommand(player, "CustomMagazines", "prepareRead", { itemId = itemId })
        return
    end
    if not CustomMagazinesServer then
        showBadText(player, "UI_CustomMagazines_ServerUnavailable")
        return
    end
    local response, reason = CustomMagazinesServer.prepareRead(player, itemId)
    if not response then
        showReadFailure(player, reason)
        return
    end
    beginRead(player, item, response)
end

local PrepareReadAction = ISBaseTimedAction:derive("ISPrepareCustomMagazineRead")

function PrepareReadAction:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.maxTime = 1
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    return o
end

function PrepareReadAction:isValid()
    return self.item ~= nil
end

function PrepareReadAction:perform()
    Client.prepareRead(self.character, self.item)
    ISBaseTimedAction.perform(self)
end

function Client.read(player, item)
    if not player or not item then return end
    if not item:getContainer() then
        showReadFailure(player, "magazine-not-in-inventory")
        return
    end
    if luautils.haveToBeTransfered(player, item, true) then
        ISInventoryPaneContextMenu.transferIfNeeded(player, item)
        ISTimedActionQueue.add(PrepareReadAction:new(player, item))
        return
    end
    Client.prepareRead(player, item)
end

function Client.rename(player, item, playerNum)
    Client.normalizeItem(item, player)
    local itemId = item:getID()
    local modal = ISTextBox:new(0, 0, 360, 180, getText("UI_CustomMagazines_RenamePrompt"), item:getName(), Client, Client.onRenameText, playerNum, playerNum, itemId)
    modal.maxChars = 64
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
end

function Client.onRenameText(target, button, playerNum, itemId)
    if not button or button.internal ~= "OK" then return end
    local title = button.parent.entry:getText()
    title = string.gsub(title or "", "^%s+", "")
    title = string.gsub(title, "%s+$", "")
    if title == "" then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    if isClient() then
        sendClientCommand(player, "CustomMagazines", "rename", { itemId = itemId, title = title })
    elseif CustomMagazinesServer then
        local ok = CustomMagazinesServer.rename(player, itemId, title)
        if not ok then showBadText(player, "UI_CustomMagazines_RenameFailed") end
    end
end

local function onInventoryContextMenu(playerNum, context, items)
    if not context or not items then return end
    local actualItems = ISInventoryPane.getActualUniqueItems(items)
    if #actualItems ~= 1 then return end
    local item = actualItems[1]
    if not item or item:getFullType() ~= CustomMagazines.ItemFullType then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    Client.normalizeItem(item, player)
    context:removeOptionByName(getText("ContextMenu_Read"))
    context:removeOptionByName(getText("ContextMenu_ReRead"))
    local folderId = item:getModData().folderId
    local label = Client.isFolderRead(player, folderId) and getText("ContextMenu_ReRead") or getText("ContextMenu_Read")
    local readOption = context:addOption(label, player, Client.read, item)
    if player:tooDarkToRead() then
        readOption.notAvailable = true
        local tooltip = ISInventoryPaneContextMenu.addToolTip()
        tooltip.description = getText("ContextMenu_TooDark")
        readOption.toolTip = tooltip
    end
    context:addOption(getText("ContextMenu_CustomMagazines_Rename"), player, Client.rename, item, playerNum)
end

local function onServerCommand(module, command, args)
    if module ~= "CustomMagazines" or not args then return end
    if command == "titleChanged" then
        if args.folderId and args.title then Client.titles[args.folderId] = args.title end
    elseif command == "folderAlias" then
        if args.oldId and args.targetId then Client.aliases[args.oldId] = args.targetId end
    elseif command == "readState" then
        Client.readFolders = args.readFolders or {}
    elseif command == "syncDone" then
        Client.updateLoadedWorld()
    elseif command == "renameResult" then
        if not args.ok then
            showBadText(getSpecificPlayer(0), "UI_CustomMagazines_RenameFailed")
        end
    elseif command == "readReady" then
        local player = Client.pendingPlayers[tostring(args.itemId)] or getSpecificPlayer(0)
        Client.pendingPlayers[tostring(args.itemId)] = nil
        local item = player and findItemById(player:getInventory(), tonumber(args.itemId), {}) or nil
        if item then beginRead(player, item, args) end
    elseif command == "readFailed" then
        local player = Client.pendingPlayers[tostring(args.itemId)] or getSpecificPlayer(0)
        Client.pendingPlayers[tostring(args.itemId)] = nil
        showReadFailure(player, args.reason)
    elseif command == "readResult" then
        if args.ok and args.folderId then
            Client.readFolders[tostring(args.folderId)] = true
        end
    end
end

function Client.installReadMarker()
    if Client.readMarkerWrapper or not ISInventoryPane or not ISInventoryPane.isLiteratureRead then return end
    Client.originalIsLiteratureRead = ISInventoryPane.isLiteratureRead
    local original = Client.originalIsLiteratureRead
    Client.readMarkerWrapper = function(pane, player, item)
        if item and item:getFullType() == CustomMagazines.ItemFullType then
            return Client.isFolderRead(player, item:getModData().folderId)
        end
        return original(pane, player, item)
    end
    ISInventoryPane.isLiteratureRead = Client.readMarkerWrapper
end

function Client.uninstallReadMarker()
    if ISInventoryPane and ISInventoryPane.isLiteratureRead == Client.readMarkerWrapper then
        ISInventoryPane.isLiteratureRead = Client.originalIsLiteratureRead
    end
    Client.readMarkerWrapper = nil
    Client.originalIsLiteratureRead = nil
end

Client.installReadMarker()

Events.OnFillInventoryObjectContextMenu.Add(onInventoryContextMenu)
Events.OnServerCommand.Add(onServerCommand)
Events.OnContainerUpdate.Add(function(object)
    if object and object.getContainer then
        local container = object:getContainer()
        if container then updateContainer(container, {}) end
    end
end)
Events.OnCreatePlayer.Add(function(playerNum, player)
    if isClient() and player then
        sendClientCommand(player, "CustomMagazines", "syncRequest", {})
    end
end)
Events.OnGameStart.Add(function()
    Client.installReadMarker()
    local root = CustomMagazines.getImageRoot()
    if root then
        local folders = CustomMagazines.listFolders(root)
        print("CustomMagazines: client registered " .. tostring(#folders) .. " local image folders.")
    end
    Client.updateLoadedWorld()
end)
