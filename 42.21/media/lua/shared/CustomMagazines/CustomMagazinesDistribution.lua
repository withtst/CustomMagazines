CustomMagazines = CustomMagazines or {}
CustomMagazines.Distribution = CustomMagazines.Distribution or {}

local Distribution = CustomMagazines.Distribution
local appliedTables = {}

function Distribution.isOrdinaryMagazine(name)
    if type(name) ~= "string" then return false end
    if name == "Magazine" or name == "MagazineCrossword" or name == "MagazineWordsearch" then
        return true
    end
    return string.match(name, "^Magazine_[%w_]+$") ~= nil
end

local function adjustItemList(items, stats)
    if type(items) ~= "table" then return end
    local totalWeight = 0
    local slotCount = 0
    for i = 1, #items - 1, 2 do
        local name = items[i]
        local weight = tonumber(items[i + 1])
        if Distribution.isOrdinaryMagazine(name) and weight and weight > 0 then
            totalWeight = totalWeight + weight
            slotCount = slotCount + 1
        end
    end
    if totalWeight <= 0 then return end

    for i = 1, #items - 1, 2 do
        local name = items[i]
        local weight = tonumber(items[i + 1])
        if Distribution.isOrdinaryMagazine(name) and weight and weight > 0 then
            items[i + 1] = weight * (2 / 3)
        end
    end

    items[#items + 1] = CustomMagazines.ItemFullType
    items[#items + 1] = totalWeight / 3
    stats.lists = stats.lists + 1
    stats.ordinarySlots = stats.ordinarySlots + slotCount
    stats.originalWeight = stats.originalWeight + totalWeight
    stats.customWeight = stats.customWeight + totalWeight / 3
end

function Distribution.apply(distributionLists, hasEffectiveMagazines)
    local stats = { lists = 0, ordinarySlots = 0, originalWeight = 0, customWeight = 0 }
    if not hasEffectiveMagazines or type(distributionLists) ~= "table" then return stats end

    local visited = {}
    local function visit(node)
        if type(node) ~= "table" or visited[node] then return end
        visited[node] = true
        if appliedTables[node] then return end
        appliedTables[node] = true
        if type(node.items) == "table" then
            adjustItemList(node.items, stats)
        end
        for _, child in pairs(node) do
            if type(child) == "table" then visit(child) end
        end
    end

    for _, list in pairs(distributionLists) do
        visit(list)
    end
    return stats
end
