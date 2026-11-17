require "CustomMagazines/CustomMagazinesCore"
require "CustomMagazines/CustomMagazinesDistribution"

CustomMagazinesServer = CustomMagazinesServer or {}
local Server = CustomMagazinesServer

Server.catalog = {}
Server.catalogIds = {}
Server.imageRoot = nil
Server.readSessions = {}
Server.worldInitialized = false
Server.loadedWorldScanned = false
Server.catalogReady = false
Server.serverStarted = false
Server.lastCatalogScanMs = nil
Server.catalogRefreshIntervalMs = 30000

local function tableSize(list)
    if not list then return 0 end
    local ok, size = pcall(function() return list:size() end)
    if ok and size then return size end
    return 0
end

local function playerKey(player)
    if not player then return "none" end
    local ok, onlineId = pcall(function() return player:getOnlineID() end)
    if ok and onlineId then return tostring(onlineId) end
    return tostring(player)
end

function Server.getState()
    local state = ModData.getOrCreate(CustomMagazines.StateKey)
    if not state.titles then state.titles = {} end
    if not state.aliases then state.aliases = {} end
    if not state.nextReadSession then state.nextReadSession = 0 end
    if type(state.spawnedThisCycle) ~= "table" then state.spawnedThisCycle = {} end
    state.version = 1
    return state
end

local function randomId(ids)
    if not ids or #ids == 0 then return nil end
    return ids[ZombRand(#ids) + 1]
end

function Server.nextSpawnFolderId(state, randomOffset)
    if not Server.catalogIds or #Server.catalogIds == 0 then return nil, false end
    state = state or Server.getState()
    if type(state.spawnedThisCycle) ~= "table" then state.spawnedThisCycle = {} end

    local available = {}
    for _, folderId in ipairs(Server.catalogIds) do
        if not state.spawnedThisCycle[folderId] then
            available[#available + 1] = folderId
        end
    end

    local startedNewCycle = false
    if #available == 0 then
        state.spawnedThisCycle = {}
        available = Server.catalogIds
        startedNewCycle = true
    end

    local offset = tonumber(randomOffset)
    if offset == nil then offset = ZombRand(#available) end
    local index = (math.floor(offset) % #available) + 1
    local selected = available[index]
    state.spawnedThisCycle[selected] = true
    return selected, startedNewCycle
end

local function readKey(folderId)
    return "CustomMagazines:" .. tostring(folderId)
end

function Server.isFolderRead(player, folderId)
    if not player or not folderId then return false end
    local key = readKey(folderId)
    local ok, pages = pcall(function() return player:getAlreadyReadPages(key) end)
    if ok and tonumber(pages) and tonumber(pages) > 0 then return true end
    local dataOk, data = pcall(function() return player:getModData() end)
    local readIds = dataOk and data and data.CustomMagazinesRead or nil
    return type(readIds) == "table" and readIds[tostring(folderId)] == true
end

local function resolveId(folderId, state, allowNewFallback)
    if not folderId then return nil end
    state = state or Server.getState()
    local current = tostring(folderId)
    local seen = {}
    while state.aliases[current] and not seen[current] do
        seen[current] = true
        current = tostring(state.aliases[current])
    end
    if Server.catalog[current] then return current end
    if allowNewFallback then
        local replacement = randomId(Server.catalogIds)
        if replacement then
            state.aliases[tostring(folderId)] = replacement
            return replacement
        end
    end
    return nil
end

function Server.resolveFolderId(folderId, state)
    return resolveId(folderId, state or Server.getState(), true)
end

function Server.reconcileAliases(state)
    state = state or Server.getState()
    if #Server.catalogIds == 0 then return false end
    local changed = false
    for oldId, targetId in pairs(state.aliases) do
        if not Server.catalog[tostring(targetId)] then
            local replacement = randomId(Server.catalogIds)
            if replacement then
                state.aliases[oldId] = replacement
                changed = true
            end
        end
    end
    for oldId in pairs(state.titles) do
        if not Server.catalog[oldId] and not state.aliases[oldId] then
            local replacement = randomId(Server.catalogIds)
            if replacement then
                state.aliases[oldId] = replacement
                changed = true
            end
        end
    end
    return changed
end

function Server.persistCatalog()
    local state = Server.getState()
    local changed = false
    for _, folderId in ipairs(Server.catalogIds) do
        if not state.titles[folderId] then
            state.titles[folderId] = CustomMagazines.defaultTitle(folderId)
            changed = true
        end
    end
    if Server.reconcileAliases(state) then changed = true end
    if changed then Server.transmitState() end
end

function Server.refreshCatalog(persist)
    local root = CustomMagazines.getImageRoot()
    Server.imageRoot = root
    Server.lastCatalogScanMs = getTimestampMs and tonumber(getTimestampMs()) or nil
    Server.catalog = {}
    Server.catalogIds = {}
    if not root then
        Server.catalogReady = true
        Server.getState().spawnedThisCycle = {}
        return Server.catalog
    end

    local folderIds = CustomMagazines.listFolders(root)
    for _, folderId in ipairs(folderIds) do
        local files = CustomMagazines.consumeScannedImages(root, folderId)
        if #files > 0 then
            Server.catalog[folderId] = { files = files, count = #files }
            Server.catalogIds[#Server.catalogIds + 1] = folderId
        end
    end
    Server.catalogReady = true
    local state = Server.getState()
    for folderId in pairs(state.spawnedThisCycle) do
        if not Server.catalog[folderId] then state.spawnedThisCycle[folderId] = nil end
    end
    if persist then
        Server.persistCatalog()
    end
    return Server.catalog
end

function Server.ensureCatalog(persist)
    local now = getTimestampMs and tonumber(getTimestampMs()) or nil
    local root = CustomMagazines.getImageRoot()
    local last = Server.lastCatalogScanMs
    if not Server.catalogReady or root ~= Server.imageRoot or not now or not last
        or now < last or now - last >= Server.catalogRefreshIntervalMs then
        Server.refreshCatalog(persist)
        return true
    end
    return false
end

function Server.refreshCatalogForFolder(folderId, persist)
    if Server.ensureCatalog(persist) then return Server.catalog end
    local resolved = folderId and resolveId(folderId, Server.getState(), false) or nil
    if not resolved then return Server.refreshCatalog(persist) end
    local files = CustomMagazines.listImages(Server.imageRoot, resolved)
    if #files == 0 then return Server.refreshCatalog(persist) end
    Server.catalog[resolved] = { files = files, count = #files }
    return Server.catalog
end

function Server.transmitState()
    -- GlobalModData initializes before the dedicated server has created udpEngine.
    if not Server.serverStarted then return end
    pcall(function() ModData.transmit(CustomMagazines.StateKey) end)
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    for i = 0, tableSize(players) - 1 do
        local player = players:get(i)
        if player then Server.sendStateTo(player) end
    end
end

function Server.sendStateTo(player)
    if not player then return end
    local state = Server.getState()
    for folderId, title in pairs(state.titles) do
        sendServerCommand(player, "CustomMagazines", "titleChanged", { folderId = folderId, title = title })
    end
    for oldId, targetId in pairs(state.aliases) do
        sendServerCommand(player, "CustomMagazines", "folderAlias", { oldId = oldId, targetId = targetId })
    end
    local playerData = player:getModData()
    local readFolders = playerData and playerData.CustomMagazinesRead or {}
    sendServerCommand(player, "CustomMagazines", "readState", { readFolders = readFolders })
    sendServerCommand(player, "CustomMagazines", "syncDone", {})
end

local function setItemFolder(item, folderId, state)
    if not item or item:getFullType() ~= CustomMagazines.ItemFullType then return false end
    local data = item:getModData()
    local resolved = resolveId(folderId or data.folderId, state, true)
    if not resolved then return false end
    local record = Server.catalog[resolved]
    if not record or record.count < 1 then return false end

    local changed = false
    if data.folderId ~= resolved then
        data.folderId = resolved
        changed = true
    end
    local title = state.titles[resolved] or CustomMagazines.defaultTitle(resolved)
    if item:getName() ~= title then
        item:setName(title)
        changed = true
    end
    if item:getNumberOfPages() ~= record.count then
        item:setNumberOfPages(record.count)
        item:setAlreadyReadPages(0)
        changed = true
    end
    if type(state.spawnedThisCycle) ~= "table" then state.spawnedThisCycle = {} end
    state.spawnedThisCycle[resolved] = true
    return changed
end

local function updateContainer(container, owner, visitedContainers)
    if not container or not container.getItems or not visitedContainers or visitedContainers[container] then return false end
    visitedContainers[container] = true
    local changed = false
    local state = Server.getState()
    local items = container:getItems()
    for i = 0, tableSize(items) - 1 do
        local item = items:get(i)
        if item and item:getFullType() == CustomMagazines.ItemFullType then
            if setItemFolder(item, item:getModData().folderId, state) then
                changed = true
                if owner and syncItemFields then pcall(syncItemFields, owner, item) end
            end
        end
        if item and instanceof(item, "InventoryContainer") then
            if updateContainer(item:getInventory(), owner, visitedContainers) then changed = true end
        end
    end
    if changed then pcall(function() container:setDirty(true) end) end
    return changed
end

local function updateOnlinePlayers(onlyFolderId)
    if Server.serverStarted then
        local players = getOnlinePlayers and getOnlinePlayers() or nil
        local visitedContainers = {}
        for i = 0, tableSize(players) - 1 do
            local player = players:get(i)
            if player and player:getInventory() then
                updateContainer(player:getInventory(), player, visitedContainers)
            end
        end
        return
    end
    if isServer and isServer() then return end
    if isClient and isClient() then return end
    local player = getSpecificPlayer and getSpecificPlayer(0) or nil
    if not player and getPlayer then player = getPlayer() end
    if player and player:getInventory() then updateContainer(player:getInventory(), player, {}) end
end

function Server.updateLoadedWorld()
    local cell = getCell and getCell() or nil
    if not cell then return end
    updateOnlinePlayers()
    local state = Server.getState()

    local minX, maxX = cell:getMinX(), cell:getMaxX()
    local minY, maxY = cell:getMinY(), cell:getMaxY()
    local minZ, maxZ = cell:getMinZ(), cell:getMaxZ()
    local squareCount = 0
    local visitedContainers = {}
    local scanLimit = 1000000
    for z = minZ, maxZ do
        for y = minY, maxY do
            for x = minX, maxX do
                squareCount = squareCount + 1
                if squareCount > scanLimit then
                    print("CustomMagazines: loaded-world name refresh reached its square limit; remaining items will refresh when loaded or used.")
                    return
                end
                local square = cell:getGridSquare(x, y, z)
                if square then
                    local groundItems = square:getWorldObjects()
                    for i = 0, tableSize(groundItems) - 1 do
                        local worldItem = groundItems:get(i)
                        if worldItem then setItemFolder(worldItem:getItem(), nil, state) end
                    end
                    local objects = square:getObjects()
                    for i = 0, tableSize(objects) - 1 do
                        local object = objects:get(i)
                        if object and object:getContainerCount() > 0 then
                            updateContainer(object:getContainer(), nil, visitedContainers)
                        end
                    end
                end
            end
        end
    end
end

function Server.onCreateItem(item)
    if isClient and isClient() and not (isServer and isServer()) then return end
    if not Server.catalogReady or not Server.imageRoot or #Server.catalogIds == 0 then Server.ensureCatalog(true) end
    if #Server.catalogIds == 0 then return end
    local state = Server.getState()
    local folderId = Server.nextSpawnFolderId(state)
    if folderId and ModData and ModData.transmit then
        pcall(function() ModData.transmit(CustomMagazines.StateKey) end)
    end
    setItemFolder(item, folderId, state)
end

function Server.applyDistributionWeights()
    if not ProceduralDistributions or not ProceduralDistributions.list then return end
    local hasFolders = #Server.catalogIds > 0
    local stats = CustomMagazines.Distribution.apply(ProceduralDistributions.list, hasFolders)
    Server.distributionStats = stats
    if stats.lists > 0 then
        print(string.format("CustomMagazines: split ordinary magazine weight across %d distribution lists (%d slots, original %.3f, custom %.3f).", stats.lists, stats.ordinarySlots, stats.originalWeight, stats.customWeight))
    elseif not hasFolders then
        print("CustomMagazines: no supported image folders; vanilla loot weights left unchanged.")
    end
end

function Server.initializeWorld()
    if Server.worldInitialized then return end
    if not Server.catalogReady then Server.refreshCatalog(false) end
    Server.persistCatalog()
    Server.worldInitialized = true
end

function Server.scanLoadedWorldIfReady()
    if Server.loadedWorldScanned then return end
    local cell = getCell and getCell() or nil
    if not cell then return end
    if cell:getMaxX() <= cell:getMinX() or cell:getMaxY() <= cell:getMinY() then return end
    Server.updateLoadedWorld()
    Server.loadedWorldScanned = true
end

local function validPlayer(player)
    return player and not player:isDead()
end

local function findItemById(container, itemId, visited)
    if not container or visited[container] then return nil end
    visited[container] = true
    local items = container:getItems()
    for i = 0, tableSize(items) - 1 do
        local item = items:get(i)
        if item and item:getID() == itemId then return item end
        if item and instanceof(item, "InventoryContainer") then
            local found = findItemById(item:getInventory(), itemId, visited)
            if found then return found end
        end
    end
    return nil
end

local function findMagazine(player, itemId)
    if not validPlayer(player) or not itemId then return nil end
    local numericId = tonumber(itemId)
    if not numericId or numericId < 0 then return nil end
    local inventory = player:getInventory()
    if not inventory then return nil end
    local item = findItemById(inventory, numericId, {})
    if not item or item:getFullType() ~= CustomMagazines.ItemFullType then return nil end
    return item
end

function Server.prepareRead(player, itemId)
    if not validPlayer(player) then return nil, "invalid-player" end
    local item = findMagazine(player, itemId)
    if not item then return nil, "magazine-not-in-inventory" end

    Server.refreshCatalogForFolder(item:getModData().folderId, true)
    local state = Server.getState()
    local itemData = item:getModData()
    local folderId = resolveId(itemData.folderId, state, true)
    local record = folderId and Server.catalog[folderId] or nil
    if not record or record.count < 1 then return nil, "no-supported-pages" end

    local playerId = playerKey(player)
    local itemIdText = tostring(item:getID())
    local byPlayer = Server.readSessions[playerId]
    if byPlayer and byPlayer[itemIdText] then return nil, "already-reading" end

    itemData.folderId = folderId
    if item:getName() ~= (state.titles[folderId] or CustomMagazines.defaultTitle(folderId)) then
        item:setName(state.titles[folderId] or CustomMagazines.defaultTitle(folderId))
    end
    item:setNumberOfPages(record.count)
    item:setAlreadyReadPages(0)
    state.nextReadSession = state.nextReadSession + 1
    local sessionId = state.nextReadSession
    byPlayer = byPlayer or {}
    Server.readSessions[playerId] = byPlayer
    byPlayer[itemIdText] = {
        id = sessionId,
        itemId = itemIdText,
        folderId = folderId,
        pageCount = record.count,
        viewedPages = {},
        viewedCount = 0,
    }
    if syncItemFields then pcall(syncItemFields, player, item) end

    return {
        itemId = itemIdText,
        folderId = folderId,
        title = item:getName(),
        pageCount = record.count,
        fileSignature = CustomMagazines.folderSignature(record.files),
        sessionId = sessionId,
        alreadyRead = Server.isFolderRead(player, folderId),
    }
end

function Server.recordReadPage(player, itemId, sessionId, pageNumber)
    if not validPlayer(player) then return false end
    local item = findMagazine(player, itemId)
    if not item then return false end
    local byPlayer = Server.readSessions[playerKey(player)]
    local key = tostring(item:getID())
    local session = byPlayer and byPlayer[key] or nil
    if not session or tonumber(sessionId) ~= session.id then return false end
    local page = tonumber(pageNumber)
    if not page or page ~= math.floor(page) or page < 1 or page > session.pageCount then return false end
    if not session.viewedPages[page] then
        session.viewedPages[page] = true
        session.viewedCount = session.viewedCount + 1
    end
    return true
end

function Server.abortRead(player, itemId, sessionId)
    local byPlayer = Server.readSessions[playerKey(player)]
    if not byPlayer then return end
    local key = tostring(itemId)
    local session = byPlayer[key]
    if session and (not sessionId or tonumber(sessionId) == session.id) then
        byPlayer[key] = nil
    end
end

function Server.completeRead(player, itemId, requestedSessionId)
    if not validPlayer(player) then return false, "invalid-player" end
    local item = findMagazine(player, itemId)
    if not item then return false, "magazine-not-in-inventory" end
    local byPlayer = Server.readSessions[playerKey(player)]
    local session = byPlayer and byPlayer[tostring(item:getID())] or nil
    if requestedSessionId and (not session or tonumber(requestedSessionId) ~= session.id) then return false, "invalid-session" end
    if not session then return false, "no-session" end
    byPlayer[tostring(item:getID())] = nil

    if (tonumber(session.viewedCount) or 0) < session.pageCount then
        return false, "pages-incomplete"
    end

    local folderId = tostring(session.folderId)
    local readIds = player:getModData().CustomMagazinesRead
    if type(readIds) ~= "table" then
        readIds = {}
        player:getModData().CustomMagazinesRead = readIds
    end
    local alreadyRead = Server.isFolderRead(player, folderId)
    readIds[folderId] = true
    player:setAlreadyReadPages(readKey(folderId), session.pageCount)
    item:setAlreadyReadPages(session.pageCount)
    item:getModData().customMagazineRead = true

    local rewardApplied = false
    if not alreadyRead then
        local plan = CustomMagazines.rewardForPages(session.pageCount)
        if not plan then return false, "invalid-page-count" end
        local stats = player:getStats()
        if plan.clear then
            stats:reset(CharacterStat.UNHAPPINESS)
            stats:reset(CharacterStat.STRESS)
            stats:reset(CharacterStat.PANIC)
        else
            stats:remove(CharacterStat.UNHAPPINESS, plan.unhappiness)
            stats:remove(CharacterStat.STRESS, plan.stress)
            stats:remove(CharacterStat.PANIC, plan.panic)
        end
        rewardApplied = true
    end
    if sendSyncPlayerFields then pcall(sendSyncPlayerFields, player, 0x00000007) end
    print(string.format(
        "CustomMagazines: player %s completed %d pages; rewardApplied=%s.",
        tostring(player:getOnlineID()), session.pageCount, tostring(rewardApplied)
    ))
    return true, rewardApplied, folderId
end

function Server.rename(player, itemId, newTitle)
    if not validPlayer(player) then return false, "invalid-player" end
    local item = findMagazine(player, itemId)
    if not item then return false, "magazine-not-in-inventory" end

    local ok, title = pcall(CustomMagazines.sanitizeTitle, newTitle)
    if not ok or type(title) ~= "string" or title == "" then return false, "invalid-title" end
    Server.refreshCatalogForFolder(item:getModData().folderId, true)
    local state = Server.getState()
    local folderId = resolveId(item:getModData().folderId, state, true)
    if not folderId then return false, "folder-unavailable" end

    state.titles[folderId] = title
    item:setName(title)
    if syncItemFields then pcall(syncItemFields, player, item) end
    Server.updateLoadedWorld()
    Server.transmitState()
    return true, { folderId = folderId, title = title }
end

local function onClientCommand(module, command, player, args)
    if module ~= "CustomMagazines" or not args then return end
    if command == "prepareRead" then
        local result, err = Server.prepareRead(player, args.itemId)
        if result then
            sendServerCommand(player, "CustomMagazines", "readReady", result)
        else
            sendServerCommand(player, "CustomMagazines", "readFailed", { itemId = args.itemId, reason = err })
        end
    elseif command == "abortRead" then
        Server.abortRead(player, args.itemId, args.sessionId)
    elseif command == "pageViewed" then
        Server.recordReadPage(player, args.itemId, args.sessionId, args.page)
    elseif command == "completeRead" then
        local ok, rewardApplied, folderId = Server.completeRead(player, args.itemId, args.sessionId)
        sendServerCommand(player, "CustomMagazines", "readResult", {
            ok = ok == true,
            rewardApplied = rewardApplied == true,
            folderId = folderId,
        })
    elseif command == "normalizeItem" then
        local item = findMagazine(player, args.itemId)
        if item then
            Server.refreshCatalogForFolder(item:getModData().folderId, true)
            if setItemFolder(item, item:getModData().folderId, Server.getState()) and syncItemFields then
                pcall(syncItemFields, player, item)
            end
        end
    elseif command == "rename" then
        local ok, value = Server.rename(player, args.itemId, args.title)
        if ok then
            sendServerCommand(player, "CustomMagazines", "renameResult", { ok = true, folderId = value.folderId, title = value.title })
        else
            sendServerCommand(player, "CustomMagazines", "renameResult", { ok = false, reason = value })
        end
    elseif command == "syncRequest" then
        Server.sendStateTo(player)
    end
end

local function isItemContainer(value)
    if not value or type(value) == "string" or not instanceof then return false end
    return instanceof(value, "ItemContainer")
end

local function onFillContainer(roomName, containerTypeOrContainer, container)
    if not Server.imageRoot then return end
    local candidate = container
    if not isItemContainer(candidate) then
        candidate = containerTypeOrContainer
    end
    if isItemContainer(candidate) then
        updateContainer(candidate, nil, {})
    end
end

Events.OnPreDistributionMerge.Add(function()
    Server.refreshCatalog(false)
    Server.applyDistributionWeights()
end)
Events.OnInitGlobalModData.Add(function()
    Server.initializeWorld()
end)
Events.OnServerStarted.Add(function()
    Server.serverStarted = true
    Server.initializeWorld()
    Server.scanLoadedWorldIfReady()
end)
Events.OnGameStart.Add(function()
    Server.initializeWorld()
    Server.scanLoadedWorldIfReady()
end)
Events.OnFillContainer.Add(onFillContainer)
Events.OnClientCommand.Add(onClientCommand)
