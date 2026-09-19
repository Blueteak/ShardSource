local addonName = ...
local addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version")
if not addonVersion or addonVersion:find("@", 1, true) then addonVersion = "development" end
local frame = CreateFrame("Frame")
local SHARD_ID, PREFIX, UNKNOWN_SOUL = 6265, "ShardSrc", "Unknown"
local ready, bankOpen, scanQueued = false, false, false
local inventory, drain, pendingAction, recentLoss, sentCast = {}, nil, nil, nil, nil
local trade, lastTrade = nil, nil
local pendingDemon
local lastSourceStatus = "No Drain Soul observed yet."
local lastShardStatus = "No new shard observed yet."
local spellActions = {}
local hookedContainers = setmetatable({}, { __mode = "k" })

local healthstones = { [5512]=true, [5511]=true, [5509]=true, [5510]=true, [9421]=true,
    [22103]=true, [22104]=true, [22105]=true }
for id = 19004, 19013 do healthstones[id] = true end
local soulstones = { [5232]=true, [16892]=true, [16893]=true, [16895]=true,
    [16896]=true, [22116]=true }
local colors = { [0]="9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000", "e6cc80" }

-- Never compare, format, persist, or send a secret value.
local function Readable(value)
    return not issecretvalue(value)
end

local function ReadableTable(value)
    return Readable(value) and type(value) == "table" and (not canaccesstable or canaccesstable(value))
end

local function PlainString(value)
    return Readable(value) and type(value) == "string" and value ~= ""
end

local function Debug(message)
    if Shards and Shards.debug then print("ShardSource: " .. message) end
end

local function SourceParts(source)
    if not PlainString(source) then return UNKNOWN_SOUL end
    local name, kind, delta, rank, level = strsplit("_", source)
    return name, kind, tonumber(delta), rank, tonumber(level)
end

local function SoulName(source)
    local name, kind, _, rank = SourceParts(source)
    if kind == "Creature" and rank == "normal" then
        return (name:match("^[aeiouAEIOU]") and "an " or "a ") .. name
    end
    return name
end

local function Quality(source)
    local _, kind, delta, rank = SourceParts(source)
    if kind == "Creature" then
        if delta == -100 or rank == "worldboss" then return 5 end
        if delta and delta < -3 then return 0 end
        if rank == "elite" or rank == "rareelite" then return 2 end
    elseif kind == "Player" then
        if delta == -100 then return 6 end
        return delta and delta >= 0 and 4 or 3
    end
    return 1
end

local function ColoredSoul(source)
    return "|cff" .. colors[Quality(source)] .. SoulName(source) .. "|r"
end

local function ChatAllowed()
    return not InCombatLockdown()
        and C_RestrictedActions.GetAddOnRestrictionState(Enum.AddOnRestrictionType.Chat)
            == Enum.AddOnRestrictionState.Inactive
end

local function Emote(message)
    if Shards.UseEmotes and ChatAllowed() then
        C_ChatInfo.SendChatMessage(message, "EMOTE")
    end
end

local function SendSource(action, source, recipient)
    if not ChatAllowed() or not PlainString(source) or not PlainString(recipient) then return end
    if recipient == UNKNOWN or recipient == UNKNOWNOBJECT then return end
    local message = action .. ":" .. source
    if #message <= 255 then C_ChatInfo.SendAddonMessage(PREFIX, message, "WHISPER", recipient) end
end

local function ItemGUID(bag, slot)
    local guid = C_Item.GetItemGUID(ItemLocation:CreateFromBagAndSlot(bag, slot))
    if PlainString(guid) then return guid end
end

local function ReadTargetSoul()
    local name = UnitName("target")
    local level, playerLevel = UnitLevel("target"), UnitLevel("player")
    local isPlayer, rank = UnitIsPlayer("target"), UnitClassification("target")
    if not PlainString(name) or not Readable(level)
        or not Readable(playerLevel) or not Readable(isPlayer) or not PlainString(rank)
        or type(level) ~= "number" or type(playerLevel) ~= "number" then
        lastSourceStatus = "Drain Soul source unavailable or restricted."
        return UNKNOWN_SOUL
    end
    if isPlayer then
        local _, class = UnitClass("target")
        if not PlainString(class) then return UNKNOWN_SOUL end
        rank = class
    end
    local kind = isPlayer and "Player" or "Creature"
    local delta = level == -1 and -100 or level - playerLevel
    -- Preserve the original saved-data / addon-message format.
    name = name:gsub("[_:|]", "")
    lastSourceStatus = "Drain Soul source readable: " .. name
    return table.concat({name, kind, delta, rank, level}, "_")
end

local function InitSpells()
    local actions = { [1120]="drain", [6201]="health", [693]="soul",
        [688]="imp",
        [697]="demon", [712]="demon", [691]="demon", [30146]="demon",
        [698]="summon", [29893]="ritual", [29858]="shatter", [20707]="protect" }
    for id, action in pairs(actions) do
        local name = C_Spell.GetSpellName(id)
        if PlainString(name) then spellActions[name] = action end
    end
end

local function BindDemonSource()
    if not pendingDemon then return end
    if pendingDemon.expires < GetTime() then pendingDemon = nil; return end
    local guid = UnitGUID("pet")
    if not PlainString(guid) or guid == pendingDemon.previousGUID then return end
    Shards.demon = { guid=guid, source=pendingDemon.source }
    pendingDemon = nil
end

local function ApplyAction(action, source)
    source = source or UNKNOWN_SOUL
    if action.kind == "health" then
        Shards.healthStoneSrc = source
    elseif action.kind == "soul" then
        Shards.soulStoneSrc = source
    elseif action.kind == "demon" then
        -- Wait for the new pet if the consumed shard arrives before UNIT_PET.
        if action.petGUID ~= nil then
            pendingDemon = { source=source, previousGUID=action.petGUID, expires=GetTime()+2 }
            BindDemonSource()
        end
        Emote("used the soul of " .. SoulName(source) .. " to cast " .. action.spell .. ".")
    elseif action.kind == "summon" then
        Emote("began summoning " .. (action.target or "a player") .. " using the soul of " .. SoulName(source) .. ".")
        SendSource("Smmn", source, action.target)
    elseif action.kind == "shatter" then
        Emote("shattered the soul of " .. SoulName(source) .. ", fading into the background.")
    elseif action.kind == "ritual" then
        Emote("brought forth a Soulwell, filled with the essence of " .. SoulName(source) .. ".")
    end
    Debug(action.kind .. " used " .. SoulName(source))
end

local function ResolveConsumption(current)
    local now = GetTime()
    if pendingAction and pendingAction.expires < now then pendingAction = nil end
    if recentLoss and (recentLoss.expires < now or current[recentLoss.guid]) then recentLoss = nil end
    if pendingAction and recentLoss and not bankOpen and not GetCursorInfo() then
        ApplyAction(pendingAction, recentLoss.source)
        Shards.sources[recentLoss.guid] = nil
        pendingAction, recentLoss = nil, nil
    end
end

local function ScanInventory()
    if not ready then return end
    local bags, current, carried = {}, {}, {}
    local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS
    for bag = 0, lastBag do bags[bag] = false end
    if bankOpen then
        for _, bankType in ipairs({Enum.BankType.Character, Enum.BankType.Account}) do
            if C_Bank.CanUseBank(bankType) then
                for _, tab in ipairs(C_Bank.FetchPurchasedBankTabData(bankType) or {}) do
                    bags[tab.ID] = true
                end
            end
        end
    end

    for bag, isBank in pairs(bags) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            local legacyKey = bag .. "x" .. slot .. "x" .. (isBank and 1 or 0)
            if Readable(itemID) and itemID == SHARD_ID then
                local guid = ItemGUID(bag, slot)
                if guid then
                    local source = Shards.sources[guid]
                    if not source then
                        source = PlainString(Shards[legacyKey]) and Shards[legacyKey] or UNKNOWN_SOUL
                        if not isBank and drain and drain.expires >= GetTime() then
                            source = drain.source
                            lastShardStatus = "New shard matched to Drain Soul: " .. SoulName(source)
                            drain = nil
                        elseif not isBank then
                            lastShardStatus = "New shard had no matching Drain Soul channel."
                        end
                        if not isBank then Debug(lastShardStatus) end
                        Shards.sources[guid] = source
                    end
                    current[guid] = { source=source, bag=bag, slot=slot }
                    if not isBank then carried[guid] = current[guid] end
                    Shards[legacyKey] = nil
                end
            elseif Readable(itemID) then
                Shards[legacyKey] = nil
            end
        end
    end

    local missing, missingCount = nil, 0
    for guid, entry in pairs(inventory) do
        if not current[guid] then
            missing, missingCount = { guid=guid, source=entry.source, expires=GetTime()+2 }, missingCount+1
        end
    end
    if missingCount > 0 then recentLoss = missingCount == 1 and missing or nil end
    ResolveConsumption(current)
    inventory = carried
end

local function PaintButton(button)
    if not ready or button:IsForbidden() then return end
    local bag, slot
    if button.GetBankTabID and button.GetContainerSlotID then
        bag, slot = button:GetBankTabID(), button:GetContainerSlotID()
    elseif button.GetBagID and button.GetID then
        bag, slot = button:GetBagID(), button:GetID()
    else
        return
    end
    if not Readable(bag) or not Readable(slot) or type(bag) ~= "number" or type(slot) ~= "number" then return end
    local itemID = C_Container.GetContainerItemID(bag, slot)
    local overlay = button.ShardSourceBorder
    if not Readable(itemID) or itemID ~= SHARD_ID then
        if overlay then overlay:Hide() end
        return
    end
    if not overlay then
        if InCombatLockdown() then return end
        overlay = button:CreateTexture(nil, "OVERLAY")
        overlay:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        overlay:SetBlendMode("ADD")
        overlay:SetPoint("TOPLEFT", button, "TOPLEFT", -7, 7)
        overlay:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 7, -7)
        button.ShardSourceBorder = overlay
    end
    local guid = ItemGUID(bag, slot)
    local source = guid and Shards.sources[guid]
    local r, g, b = C_Item.GetItemQualityColor(Quality(source))
    overlay:SetVertexColor(r, g, b)
    overlay:Show()
end

local function PaintContainer(container)
    if container:IsShown() and container.EnumerateValidItems then
        for _, button in container:EnumerateValidItems() do PaintButton(button) end
    end
end

local function PaintBank(panel)
    if panel:IsShown() and panel.EnumerateValidItems then
        for button in panel:EnumerateValidItems() do PaintButton(button) end
    end
end

local function RefreshBags()
    if not ContainerFrameUtil_EnumerateContainerFrames then return end
    for _, container in ContainerFrameUtil_EnumerateContainerFrames() do
        if not hookedContainers[container] and not InCombatLockdown() then
            hookedContainers[container] = true
            if container.UpdateItems then hooksecurefunc(container, "UpdateItems", PaintContainer) end
            container:HookScript("OnShow", PaintContainer)
        end
        PaintContainer(container)
    end
    local panel = BankFrame and BankFrame.BankPanel
    if panel and panel.EnumerateValidItems then
        if not hookedContainers[panel] and not InCombatLockdown() then
            hookedContainers[panel] = true
            hooksecurefunc(panel, "RefreshAllItemsForSelectedTab", PaintBank)
            hooksecurefunc(panel, "RefreshBankPanel", PaintBank)
        end
        PaintBank(panel)
    end
end

local function QueueScan()
    if scanQueued or not ready then return end
    scanQueued = true
    -- Bag changes and spell successes can arrive in either order.
    C_Timer.After(0.1, function()
        scanQueued = false
        ScanInventory()
        RefreshBags()
    end)
end

local function TooltipSource(tooltip, data)
    if PlainString(data.guid) and Shards.sources[data.guid] then return Shards.sources[data.guid] end
    local info = tooltip.GetPrimaryTooltipInfo and tooltip:GetPrimaryTooltipInfo()
    if not ReadableTable(info) or not Readable(info.getterName) or info.getterName ~= "GetBagItem"
        or not ReadableTable(info.getterArgs) then return end
    local bag, slot = info.getterArgs[1], info.getterArgs[2]
    if Readable(bag) and Readable(slot) and type(bag) == "number" and type(slot) == "number" then
        local guid = ItemGUID(bag, slot)
        return guid and Shards.sources[guid]
    end
end

local function ItemTooltip(tooltip, data)
    if not ready or tooltip:IsForbidden() or not ReadableTable(data) or not Readable(data.id) then return end
    if not C_RestrictedActions.CheckAllowProtectedFunctions(tooltip, true) then return end
    local id, source = data.id, nil
    if id == SHARD_ID then
        source = TooltipSource(tooltip, data) or UNKNOWN_SOUL
        local name = tooltip:GetName()
        local title = name and _G[name .. "TextLeft1"]
        local text = source == UNKNOWN_SOUL and "Unknown Soul" or SoulName(source) .. "'s Soul"
        if title then
            title:SetText(text:sub(1, 1):upper() .. text:sub(2))
            local r, g, b = C_Item.GetItemQualityColor(Quality(source))
            title:SetTextColor(r, g, b)
        else
            tooltip:AddLine(text)
        end
    elseif healthstones[id] then
        source = Shards.healthStoneSrc
        tooltip:AddLine("Soul of " .. ColoredSoul(source))
    elseif soulstones[id] then
        source = Shards.soulStoneSrc
        tooltip:AddLine("Soul of " .. ColoredSoul(source))
    else
        return
    end
    local _, kind, _, class, level = SourceParts(source)
    if kind == "Player" then
        local className = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or "Player"
        tooltip:AddLine((level and level .. " " or "") .. className, 1, 1, 1)
    end
end

local function DemonTooltip(tooltip, data)
    if not ready or tooltip:IsForbidden() or not ReadableTable(data) or not PlainString(data.guid) then return end
    if not C_RestrictedActions.CheckAllowProtectedFunctions(tooltip, true) then return end
    BindDemonSource()
    local demon, guid = Shards.demon, UnitGUID("pet")
    if not demon or not PlainString(guid) or data.guid ~= guid or demon.guid ~= guid then return end
    if not ReadableTable(data.lines) then return end
    local text = demon.source == UNKNOWN_SOUL and "<Summoned from an unknown soul>"
        or "<Summoned from " .. ColoredSoul(demon.source) .. "'s soul>"
    local name = tooltip:GetName()
    for _, line in ipairs(data.lines) do
        if ReadableTable(line) and Readable(line.type) and line.type == Enum.TooltipDataLineType.UnitOwner
            and Readable(line.lineIndex) and type(line.lineIndex) == "number" then
            local label = name and _G[name .. "TextLeft" .. line.lineIndex]
            if label then label:SetText(text); return end
        end
    end
    tooltip:AddLine(text, 1, 1, 1)
end

local function SpellEvent(event, unit, castGUID, spellID)
    if not Readable(unit) or not Readable(spellID) then
        drain, pendingAction, recentLoss, sentCast = nil, nil, nil, nil
        lastSourceStatus = "Spell information restricted; source left unknown."
        Debug(lastSourceStatus)
        return
    end
    if unit ~= "player" then return end
    local spellName = C_Spell.GetSpellName(spellID)
    if not PlainString(spellName) then return end
    local kind = spellActions[spellName]
    if kind == "drain" then
        if event == "UNIT_SPELLCAST_CHANNEL_START" then
            drain = { source=ReadTargetSoul(), expires=GetTime()+20 }
            Debug(lastSourceStatus)
        elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" and drain then
            -- Death/target clearing can precede the server's inventory update.
            drain.expires = GetTime()+3
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and kind then
        local target, petGUID
        if sentCast and Readable(castGUID) and sentCast.guid == castGUID and sentCast.expires >= GetTime() then
            target, petGUID = sentCast.target, sentCast.petGUID
        end
        if kind == "protect" then
            local source = Shards.soulStoneSrc
            Emote("protected " .. (target or "a player") .. " using the soul of " .. SoulName(source) .. ".")
            SendSource("SStone", source, target)
            Shards.soulStoneSrc = UNKNOWN_SOUL
        elseif kind == "imp" then
            -- Imps do not consume a soul shard.
            Shards.demon, pendingDemon = nil, nil
            pendingAction, recentLoss = nil, nil
        else
            pendingAction = { kind=kind, spell=spellName, target=target, petGUID=petGUID, expires=GetTime()+2 }
            -- A new stone must not inherit an older stone's source if attribution fails.
            if kind == "health" then Shards.healthStoneSrc = UNKNOWN_SOUL end
            if kind == "soul" then Shards.soulStoneSrc = UNKNOWN_SOUL end
            if kind == "demon" then Shards.demon, pendingDemon = nil, nil end
        end
        sentCast = nil
    end
    QueueScan()
end

local function UpdateTrade()
    if not trade then return end
    trade.source = nil
    for slot = 1, 6 do
        local link = GetTradePlayerItemLink(slot)
        if PlainString(link) then
            local id = C_Item.GetItemInfoInstant(link)
            if Readable(id) and healthstones[id] then trade.source = Shards.healthStoneSrc end
        end
    end
end

local function ReceiveSource(prefix, message, _, sender)
    if not Readable(prefix) or prefix ~= PREFIX or not PlainString(message) or not PlainString(sender) then return end
    if #message > 255 or message:find("[|\r\n]") then return end
    local action, source = message:match("^([^:]+):(.+)$")
    if not source then return end
    if action == "HStone" then
        -- Only the current/recent trade partner may change our healthstone source.
        local partner = trade or lastTrade
        if partner and partner.expires >= GetTime() and Ambiguate(sender, "short") == Ambiguate(partner.target, "short") then
            Shards.healthStoneSrc = source
        end
    elseif action == "SStone" then
        Shards.soulStoneSrc = source
    elseif action == "Smmn" then
        print("ShardSource: " .. sender .. " is summoning you using the soul of " .. SoulName(source) .. ".")
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= addonName then return end
        Shards = type(Shards) == "table" and Shards or {}
        Shards.sources = type(Shards.sources) == "table" and Shards.sources or {}
        if Shards.UseEmotes == nil then Shards.UseEmotes = true end
        Shards.healthStoneSrc = PlainString(Shards.healthStoneSrc) and Shards.healthStoneSrc or UNKNOWN_SOUL
        Shards.soulStoneSrc = PlainString(Shards.soulStoneSrc) and Shards.soulStoneSrc or UNKNOWN_SOUL
        if not ReadableTable(Shards.demon) or not PlainString(Shards.demon.guid)
            or not PlainString(Shards.demon.source) then Shards.demon = nil end
        Shards.schemaVersion = 2
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, ItemTooltip)
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, DemonTooltip)
        InitSpells()
        ready = true
        print("Loaded |cffa335ee[ShardSource]|r " .. addonVersion .. " for WoW Forever.")
    elseif not ready then
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        drain, pendingAction, recentLoss, sentCast = nil, nil, nil, nil
        pendingDemon = nil
        inventory = {}
        ScanInventory()
        RefreshBags()
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then
        QueueScan()
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        QueueScan()
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
        QueueScan()
    elseif event == "UNIT_SPELLCAST_SENT" then
        local unit, target, guid = ...
        if Readable(unit) and unit == "player" then
            sentCast = nil
            if PlainString(guid) then
                local petGUID = UnitGUID("pet")
                sentCast = { target=PlainString(target) and target or nil, guid=guid, expires=GetTime()+30 }
                -- false means no previous pet; nil means its identity was unavailable.
                if Readable(petGUID) and (petGUID == nil or PlainString(petGUID)) then
                    sentCast.petGUID = petGUID or false
                end
            end
        end
    elseif event == "UNIT_PET" then
        local unit = ...
        if Readable(unit) and unit == "player" then BindDemonSource() end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        SpellEvent(event, ...)
    elseif event == "CHAT_MSG_ADDON" then
        ReceiveSource(...)
    elseif event == "TRADE_SHOW" then
        local name, realm = UnitFullName("NPC")
        if PlainString(name) then
            local target = name
            if PlainString(realm) then target = target .. "-" .. realm end
            trade = { target=target, expires=GetTime()+300 }
        else
            trade = nil
        end
        lastTrade = nil
    elseif event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
        UpdateTrade()
    elseif event == "TRADE_REQUEST_CANCEL" then
        trade, lastTrade = nil, nil
    elseif event == "TRADE_CLOSED" then
        if trade then trade.expires = GetTime()+2; lastTrade = trade; trade = nil end
    elseif event == "UI_INFO_MESSAGE" then
        local _, message = ...
        if Readable(message) and message == ERR_TRADE_COMPLETE then
            local completed = trade or lastTrade
            if completed and completed.expires >= GetTime() and completed.source then
                SendSource("HStone", completed.source, completed.target)
            end
            if completed then completed.source = nil end
        end
    end
end)

for _, event in ipairs({"ADDON_LOADED", "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED",
    "PLAYER_REGEN_ENABLED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "CHAT_MSG_ADDON", "TRADE_SHOW", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_ACCEPT_UPDATE",
    "TRADE_CLOSED", "TRADE_REQUEST_CANCEL", "UI_INFO_MESSAGE"}) do
    frame:RegisterEvent(event)
end
for _, event in ipairs({"UNIT_PET", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP"}) do
    frame:RegisterUnitEvent(event, "player")
end

SLASH_SHARDSOURCE1, SLASH_SHARDSOURCE2 = "/shardsrc", "/ssrc"
SlashCmdList.SHARDSOURCE = function(message)
    if not ready then return end
    message = strtrim(message):lower()
    if message == "emote" then
        Shards.UseEmotes = not Shards.UseEmotes
        print("ShardSource emotes: " .. (Shards.UseEmotes and "on" or "off"))
    elseif message == "debug" then
        Shards.debug = not Shards.debug
        print("ShardSource debug: " .. (Shards.debug and "on" or "off"))
    elseif message == "status" then
        local version, build, _, interface = GetBuildInfo()
        local count, known = 0, 0
        for _, entry in pairs(inventory) do
            count = count+1
            if entry.source ~= UNKNOWN_SOUL then known = known+1 end
        end
        print("ShardSource " .. addonVersion .. " | WoW " .. version .. " / " .. build .. " / interface " .. interface)
        print("Shards in bags: " .. count .. "; named: " .. known .. ".")
        print(lastSourceStatus)
        print(lastShardStatus)
        print("Automatic chat: " .. (ChatAllowed() and "available" or "restricted"))
    elseif message == "testhealth" then
        print("ShardSource: healthstone soul is " .. ColoredSoul(Shards.healthStoneSrc) .. ".")
    elseif message == "testsummon" then
        SendSource("Smmn", "TestUnit", UnitName("player"))
    elseif message == "testsoulstone" then
        SendSource("SStone", Shards.soulStoneSrc, UnitName("player"))
    else
        print("ShardSource: /ssrc status, /ssrc emote, /ssrc debug")
    end
end
