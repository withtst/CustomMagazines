CustomMagazines = CustomMagazines or {}

CustomMagazines.ItemFullType = "CustomMagazines.CustomMagazine"
CustomMagazines.ConfigFile = "CustomMagazinesPath.txt"
CustomMagazines.StateKey = "CustomMagazines"
CustomMagazines.ScanCache = {}

local function trim(value)
    value = tostring(value or "")
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    return value
end

function CustomMagazines.getImageRoot()
    local reader = getFileReader(CustomMagazines.ConfigFile, false)
    if not reader then
        local writer = getFileWriter(CustomMagazines.ConfigFile, true, false)
        if writer then
            writer:write("# Absolute path to the image root. Each direct child folder is one magazine.\n")
            writer:write("# Put JPG/JPEG/PNG page files directly inside each magazine folder.\n")
            writer:write("\n")
            writer:close()
        end
        return nil
    end

    local root = nil
    while true do
        local line = reader:readLine()
        if line == nil then break end
        line = trim(line)
        if string.sub(line, 1, 3) == string.char(239, 187, 191) then
            line = string.sub(line, 4)
            line = trim(line)
        end
        local first = string.sub(line, 1, 1)
        if line ~= "" and first ~= "#" and first ~= ";" then
            root = line
            break
        end
    end
    reader:close()

    if root then
        local first = string.sub(root, 1, 1)
        local last = string.sub(root, -1)
        if (first == "\"" and last == "\"") or (first == "'" and last == "'") then
            root = string.sub(root, 2, -2)
        end
    end
    if root == "" then return nil end
    return root
end

local function callJava(method, ...)
    local names = {
        listFolders = "CMListFolders",
        listFolderNames = "CMListFolderNames",
        listImages = "CMListImages",
        defaultTitle = "CMDefaultTitle",
        sanitizeTitle = "CMSanitizeTitle",
        loadTexture = "CMLoadTexture",
        releaseTexture = "CMReleaseTexture",
        releaseAllTextures = "CMReleaseAllTextures",
    }
    local functionName = names[method]
    local fn = functionName and _G[functionName] or nil
    if not fn then return false, "Java helper is unavailable: " .. tostring(functionName) end
    return pcall(fn, ...)
end

local function copyJavaStringList(list)
    local out = {}
    if not list then return out end
    local ok, count = pcall(function() return list:size() end)
    if not ok or not count then return out end
    for i = 0, count - 1 do
        local itemOk, value = pcall(function() return list:get(i) end)
        if itemOk and value then out[#out + 1] = tostring(value) end
    end
    return out
end

function CustomMagazines.listFolders(root)
    root = root or CustomMagazines.getImageRoot()
    if not root then return {} end
    local ok, result = callJava("listFolderNames", root)
    if not ok then
        print("CustomMagazines: folder scan failed: " .. tostring(result))
        return {}
    end
    local names = copyJavaStringList(result)
    local folders = {}
    local filesByFolder = {}
    for _, folderId in ipairs(names) do
        local files = CustomMagazines.listImages(root, folderId)
        if #files > 0 then
            folders[#folders + 1] = folderId
            filesByFolder[folderId] = files
        end
    end
    CustomMagazines.ScanCache[root] = filesByFolder
    return folders
end

function CustomMagazines.listImages(root, folderId)
    root = root or CustomMagazines.getImageRoot()
    if not root or not folderId then return {} end
    local ok, result = callJava("listImages", root, tostring(folderId))
    if not ok then
        print("CustomMagazines: image scan failed: " .. tostring(result))
        return {}
    end
    return copyJavaStringList(result)
end

function CustomMagazines.consumeScannedImages(root, folderId)
    local byFolder = root and CustomMagazines.ScanCache[root] or nil
    local files = byFolder and byFolder[folderId] or nil
    if files then
        byFolder[folderId] = nil
        return files
    end
    return CustomMagazines.listImages(root, folderId)
end

function CustomMagazines.folderSignature(files)
    local hash = 7
    for _, filename in ipairs(files or {}) do
        for i = 1, #filename do
            hash = (hash * 65599 + string.byte(filename, i)) % 2147483647
        end
        hash = (hash * 65599 + 10) % 2147483647
    end
    return tostring(hash) .. ":" .. tostring(#(files or {}))
end

function CustomMagazines.defaultTitle(folderId)
    if type(folderId) ~= "string" or folderId == "" then return "Magazine" end
    local ok, value = callJava("defaultTitle", folderId)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return string.sub(folderId, 1, 4)
end

function CustomMagazines.sanitizeTitle(title)
    if type(title) ~= "string" then return nil end
    local ok, value = callJava("sanitizeTitle", title)
    if ok and type(value) == "string" then return value end
    local trimmed = string.gsub(title, "^%s+", "")
    trimmed = string.gsub(trimmed, "%s+$", "")
    return string.sub(trimmed, 1, 32)
end

function CustomMagazines.releaseTexture(ownerKey)
    if ownerKey then
        callJava("releaseTexture", tostring(ownerKey))
    else
        callJava("releaseAllTextures")
    end
end

function CustomMagazines.loadTexture(root, folderId, filename, ownerKey)
    local ok, result = callJava("loadTexture", root, tostring(folderId), tostring(filename), tostring(ownerKey or "default"))
    if not ok then
        print("CustomMagazines: image decode failed: " .. tostring(result))
        return nil
    end
    return result
end

function CustomMagazines.rewardForPages(pageCount)
    pageCount = tonumber(pageCount) or 0
    if pageCount >= 21 then
        return { clear = true }
    end
    if pageCount >= 11 then
        return { unhappiness = 65, stress = 0.65, panic = 65 }
    end
    if pageCount >= 1 then
        return { unhappiness = 30, stress = 0.30, panic = 30 }
    end
    return nil
end

function CustomMagazines.pageDisplaySize(textureWidth, textureHeight, screenWidth, screenHeight)
    textureWidth = tonumber(textureWidth) or 0
    textureHeight = tonumber(textureHeight) or 0
    screenWidth = tonumber(screenWidth) or 0
    screenHeight = tonumber(screenHeight) or 0
    if textureWidth <= 0 or textureHeight <= 0 or screenWidth <= 0 or screenHeight <= 0 then
        return 1, 1
    end

    local maxWidth = math.max(1, math.floor(screenWidth * 2 / 3))
    local maxHeight = math.max(1, math.floor(screenHeight * 2 / 3))
    local scale = math.min(maxWidth / textureWidth, maxHeight / textureHeight)
    return math.max(1, math.floor(textureWidth * scale)), math.max(1, math.floor(textureHeight * scale))
end
