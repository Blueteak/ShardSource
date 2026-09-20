local addonName = ...
local addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version")
if not addonVersion or addonVersion:find("@", 1, true) then addonVersion = "development" end
local TRACKING_REVISION = "2026-09-19.2"
local frame = CreateFrame("Frame")
local SHARD_ID, PREFIX, UNKNOWN_SOUL = 6265, "ShardSrc", "Unknown"
local ready, bankOpen, scanQueued = false, false, false
local inventory, drain, pendingAction, recentLoss, sentCast = {}, nil, nil, nil, nil
local trade, lastTrade = nil, nil
local pendingDemon
local observedDemon, demonRefund
local recentGains, inventoryReady = {}, false
local REFUND_WINDOW = 3
local lastSourceStatus = "No Drain Soul observed yet."
local lastShardStatus = "No new shard observed yet."
local lastSpellStatus = "No restricted spell events observed."
local lastRecoveryStatus = "No delayed name lookup attempted."
local lastDisplayStatus = "No temporary soul name displayed yet."
-- These records may hold opaque names/GUIDs. Never put them in saved variables.
local sessionSouls, healthSoul, stoneSoul, demonSoul = {}, nil, nil, nil
local recoveryQueued = false
local loadedSourceStatus
local spellActions = {}
local hookedContainers = setmetatable({}, { __mode = "k" })

local healthstones = { [5512]=true, [5511]=true, [5509]=true, [5510]=true, [9421]=true,
    [22103]=true, [22104]=true, [22105]=true }
for id = 19004, 19013 do healthstones[id] = true end
local soulstones = { [5232]=true, [16892]=true, [16893]=true, [16895]=true,
    [16896]=true, [22116]=true }
local colors = { [0]="9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000", "e6cc80" }

-- Secret values stay opaque in session records and go only to supported APIs.
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
        -- Elite difficulty takes priority over being below the player's level.
        if rank == "elite" or rank == "rareelite" then return 2 end
        if delta and delta < -3 then return 0 end
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

local function ValidSoulName(name)
    return PlainString(name) and name ~= UNKNOWN and name ~= UNKNOWNOBJECT
end

local function RecordedSource(source, soul)
    return soul and soul.source ~= UNKNOWN_SOUL and soul.source or source or UNKNOWN_SOUL
end

local function SavedSourceStatus()
    local count, known = 0, 0
    for _, source in pairs(Shards.sources) do
        count = count+1
        if PlainString(source) and source ~= UNKNOWN_SOUL then known = known+1 end
    end
    return known .. " named / " .. count .. " shard records"
end

local function ReadTargetSoul()
    local name = UnitName("target")
    local guid = UnitGUID("target")
    local level, playerLevel = UnitLevel("target"), UnitLevel("player")
    local isPlayer, rank = UnitIsPlayer("target"), UnitClassification("target")
    -- Missing quality metadata must not discard a readable soul name.
    level = Readable(level) and type(level) == "number" and level or nil
    playerLevel = Readable(playerLevel) and type(playerLevel) == "number" and playerLevel or nil
    rank = PlainString(rank) and rank or "unknown"
    local kind = "Unknown"
    if Readable(isPlayer) then kind = isPlayer and "Player" or "Creature" end
    if kind == "Player" then
        local _, class = UnitClass("target")
        rank = PlainString(class) and class or "unknown"
    end
    local delta = level == -1 and -100 or level and playerLevel and level - playerLevel
    local details = table.concat({kind, delta or "", rank, level or ""}, "_")
    if not ValidSoulName(name) then
        local soul = { source=UNKNOWN_SOUL, details=details,
            quality=Quality(UNKNOWN_SOUL .. "_" .. details),
            hasName=not Readable(name), hasGUID=not Readable(guid) or PlainString(guid) }
        -- Do not branch on, concatenate, or use a protected name/GUID as a key.
        if soul.hasName then soul.name = name end
        if soul.hasGUID then soul.guid = guid end
        lastSourceStatus = soul.hasName and "Restricted Drain Soul name kept for this session."
            or "Drain Soul name unavailable; saved creature identity for a later lookup."
        if not soul.hasName and not soul.hasGUID then
            lastSourceStatus = "Drain Soul target name and identity were unavailable."
            return UNKNOWN_SOUL
        end
        return UNKNOWN_SOUL, soul
    end
    -- Preserve the original saved-data / addon-message format.
    name = name:gsub("[_:|]", "")
    lastSourceStatus = "Drain Soul source readable: " .. name
    return name .. "_" .. details
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
    demonSoul = pendingDemon.soul
    Shards.demon = { guid=guid, source=RecordedSource(pendingDemon.source, demonSoul) }
    observedDemon = { guid=guid, source=Shards.demon.source, soul=demonSoul }
    pendingDemon = nil
end

local function ObserveDemon()
    local guid = UnitGUID("pet")
    if not Readable(guid) then
        observedDemon, demonRefund = nil, nil
    elseif guid == nil then
        if observedDemon and inventoryReady and not bankOpen
            and (observedDemon.source ~= UNKNOWN_SOUL or observedDemon.soul) then
            demonRefund = { guid=observedDemon.guid, source=observedDemon.source,
                soul=observedDemon.soul, expires=GetTime()+REFUND_WINDOW }
        end
        observedDemon = nil
    elseif PlainString(guid) then
        demonRefund = nil
        observedDemon = nil
        if Shards.demon and Shards.demon.guid == guid then
            observedDemon = { guid=guid, source=Shards.demon.source, soul=demonSoul }
        end
    end
end

local function ApplyAction(action, source, soul)
    source = RecordedSource(source, soul)
    if action.kind == "health" then
        Shards.healthStoneSrc = source
        healthSoul = soul
    elseif action.kind == "soul" then
        Shards.soulStoneSrc = source
        stoneSoul = soul
    elseif action.kind == "demon" then
        -- Wait for the new pet if the consumed shard arrives before UNIT_PET.
        if action.petGUID ~= nil then
            pendingDemon = { source=source, soul=soul, previousGUID=action.petGUID, expires=GetTime()+2 }
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
        ApplyAction(pendingAction, recentLoss.source, recentLoss.soul)
        Shards.sources[recentLoss.guid] = nil
        sessionSouls[recentLoss.guid] = nil
        pendingAction, recentLoss = nil, nil
    end
end

local function ResolveDemonRefund(carried)
    local now, candidate, count = GetTime(), nil, 0
    if demonRefund and demonRefund.expires < now then demonRefund = nil end
    for guid, expires in pairs(recentGains) do
        if expires < now or not carried[guid] or carried[guid].source ~= UNKNOWN_SOUL or sessionSouls[guid] then
            recentGains[guid] = nil
        else
            candidate, count = guid, count+1
        end
    end
    if not demonRefund or bankOpen or GetCursorInfo() then return end
    if count > 1 then
        -- Do not choose arbitrarily when several unidentified shards appear together.
        demonRefund, recentGains = nil, {}
        lastShardStatus = "Demon disappeared with multiple new shards; returned soul left unknown."
        Debug(lastShardStatus)
    elseif count == 1 then
        local soul = demonRefund.soul
        local source = RecordedSource(demonRefund.source, soul)
        Shards.sources[candidate], carried[candidate].source = source, source
        sessionSouls[candidate], carried[candidate].soul = soul, soul
        if Shards.demon and Shards.demon.guid == demonRefund.guid then
            Shards.demon, demonSoul = nil, nil
        end
        demonRefund, recentGains = nil, {}
        lastShardStatus = soul and source == UNKNOWN_SOUL and "Returned shard kept the demon's temporary soul record."
            or "Returned shard matched to summoned demon: " .. SoulName(source)
        Debug(lastShardStatus)
    end
end

local function ScanInventory()
    if not ready then return end
    ObserveDemon()
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
                            source = RecordedSource(drain.source, drain.soul)
                            sessionSouls[guid] = drain.soul
                            lastShardStatus = drain.soul and source == UNKNOWN_SOUL
                                and "New shard matched to Drain Soul; temporary name/recovery record attached."
                                or source == UNKNOWN_SOUL
                                and "New shard matched to Drain Soul, but " .. drain.reason
                                or "New shard matched to Drain Soul: " .. SoulName(source)
                            drain = nil
                        elseif not isBank then
                            lastShardStatus = "New shard had no matching Drain Soul channel."
                            if inventoryReady and source == UNKNOWN_SOUL and not bankOpen and not GetCursorInfo() then
                                -- Keep it briefly in case the pet disappearance arrives after the bag update.
                                recentGains[guid] = GetTime()+REFUND_WINDOW
                            end
                        end
                        if not isBank then Debug(lastShardStatus) end
                        Shards.sources[guid] = source
                    end
                    current[guid] = { source=source, soul=sessionSouls[guid], bag=bag, slot=slot }
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
            missing, missingCount = { guid=guid, source=entry.source, soul=entry.soul, expires=GetTime()+2 }, missingCount+1
        end
    end
    ResolveDemonRefund(carried)
    if missingCount > 0 then recentLoss = missingCount == 1 and missing or nil end
    ResolveConsumption(current)
    inventory = carried
    inventoryReady = true
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
    local soul = guid and sessionSouls[guid]
    local r, g, b = C_Item.GetItemQualityColor(soul and soul.quality or Quality(source))
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

local function RecoverSouls()
    local checked, recovered, restricted, unavailable, failed = {}, 0, 0, 0, 0
    local savedShards = 0
    local function Recover(soul)
        if not soul or soul.source ~= UNKNOWN_SOUL or checked[soul] then return end
        checked[soul] = true
        if not soul.hasGUID or not UnitNameFromGUID then
            unavailable = unavailable+1
            return
        end
        -- A fresh lookup for the original creature only. Never re-read today's target.
        local ok, name = pcall(UnitNameFromGUID, soul.guid)
        if not ok then
            failed = failed+1
        elseif not Readable(name) then
            restricted = restricted+1
            if not soul.hasName then soul.name, soul.hasName = name, true end
        elseif ValidSoulName(name) then
            local source = name:gsub("[_:|]", "") .. "_" .. soul.details
            if PlainString(source) then
                soul.source = source
                soul.name, soul.guid, soul.hasName, soul.hasGUID = nil, nil, false, false
                recovered = recovered+1
            else
                restricted = restricted+1
            end
        else
            unavailable = unavailable+1
        end
    end
    local function UpdateEntry(entry)
        if entry then
            Recover(entry.soul)
            entry.source = RecordedSource(entry.source, entry.soul)
        end
    end
    for guid, soul in pairs(sessionSouls) do
        Recover(soul)
        local source = RecordedSource(Shards.sources[guid], soul)
        -- A readable session record is enough to restore its saved entry, even if
        -- that entry is missing. Count the write separately from the name lookup.
        if PlainString(source) and source ~= UNKNOWN_SOUL then
            if Shards.sources[guid] ~= source then savedShards = savedShards+1 end
            Shards.sources[guid] = source
        end
        UpdateEntry(inventory[guid])
    end
    Recover(healthSoul)
    Recover(stoneSoul)
    Recover(demonSoul)
    Shards.healthStoneSrc = RecordedSource(Shards.healthStoneSrc, healthSoul)
    Shards.soulStoneSrc = RecordedSource(Shards.soulStoneSrc, stoneSoul)
    if Shards.demon then Shards.demon.source = RecordedSource(Shards.demon.source, demonSoul) end
    for _, entry in pairs({pendingDemon, observedDemon, demonRefund, recentLoss, drain, sentCast}) do
        UpdateEntry(entry)
    end
    if next(checked) or savedShards > 0 then
        lastRecoveryStatus = "Delayed names: " .. recovered .. " recovered; " .. restricted
            .. " still restricted; " .. unavailable .. " unavailable; " .. failed .. " lookup errors; "
            .. savedShards .. " shard records updated."
        Shards.lastRecoveryStatus = lastRecoveryStatus
        Debug(lastRecoveryStatus)
        return lastRecoveryStatus
    end
end

local function QueueRecovery()
    if recoveryQueued or not ready then return end
    recoveryQueued = true
    -- Restriction changes are announced before activation/after deactivation.
    -- Let the event finish before trying the lookup, including on zone changes.
    C_Timer.After(0.5, function()
        recoveryQueued = false
        RecoverSouls()
        RefreshBags()
    end)
end

local function QueueScan()
    if scanQueued or not ready then return end
    scanQueued = true
    -- Bag changes and spell successes can arrive in either order.
    C_Timer.After(0.1, function()
        scanQueued = false
        ScanInventory()
        RefreshBags()
        QueueRecovery()
    end)
end

local function TooltipSource(tooltip, data)
    if PlainString(data.guid) and Shards.sources[data.guid] then
        return Shards.sources[data.guid], sessionSouls[data.guid]
    end
    local info = tooltip.GetPrimaryTooltipInfo and tooltip:GetPrimaryTooltipInfo()
    if not ReadableTable(info) or not Readable(info.getterName) or info.getterName ~= "GetBagItem"
        or not ReadableTable(info.getterArgs) then return end
    local bag, slot = info.getterArgs[1], info.getterArgs[2]
    if Readable(bag) and Readable(slot) and type(bag) == "number" and type(slot) == "number" then
        local guid = ItemGUID(bag, slot)
        if guid then return Shards.sources[guid], sessionSouls[guid] end
    end
end

local function SetSoulText(label, fallback, soul, format)
    if soul and soul.source == UNKNOWN_SOUL and soul.hasName then
        -- SetFormattedText is an allowed display sink. Lua must not format this name.
        local ok = pcall(label.SetFormattedText, label, format, soul.name)
        if ok then
            lastDisplayStatus = "Temporary soul name passed to the tooltip renderer."
            return
        end
        lastDisplayStatus = "WoW rejected temporary name display; normal label used."
    end
    label:SetText(fallback)
end

local function AddSoulLine(tooltip, fallback, soul, format)
    tooltip:AddLine(fallback, 1, 1, 1)
    local name, line = tooltip:GetName(), tooltip:NumLines()
    if PlainString(name) and Readable(line) and type(line) == "number" then
        local label = _G[name .. "TextLeft" .. line]
        if label then SetSoulText(label, fallback, soul, format) end
    end
end

local function ItemTooltip(tooltip, data)
    if not ready or tooltip:IsForbidden() or not ReadableTable(data) or not Readable(data.id) then return end
    if not C_RestrictedActions.CheckAllowProtectedFunctions(tooltip, true) then return end
    local id, source, soul = data.id, nil, nil
    if id == SHARD_ID then
        source, soul = TooltipSource(tooltip, data)
        source = RecordedSource(source, soul)
        local name = tooltip:GetName()
        local title = name and _G[name .. "TextLeft1"]
        local text = source == UNKNOWN_SOUL and "Unknown Soul" or SoulName(source) .. "'s Soul"
        if title then
            SetSoulText(title, text:sub(1, 1):upper() .. text:sub(2), soul, "%s's Soul")
            local r, g, b = C_Item.GetItemQualityColor(soul and soul.quality or Quality(source))
            title:SetTextColor(r, g, b)
        else
            AddSoulLine(tooltip, text, soul, "%s's Soul")
        end
    elseif healthstones[id] then
        source = Shards.healthStoneSrc
        soul = healthSoul
    elseif soulstones[id] then
        source = Shards.soulStoneSrc
        soul = stoneSoul
    else
        return
    end
    if id ~= SHARD_ID then
        AddSoulLine(tooltip, "Soul of " .. ColoredSoul(source), soul,
            "Soul of |cff" .. colors[soul and soul.quality or Quality(source)] .. "%s|r")
    end
    if soul and source == UNKNOWN_SOUL then source = UNKNOWN_SOUL .. "_" .. soul.details end
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
    local format = "<Summoned from |cff" .. colors[demonSoul and demonSoul.quality or Quality(demon.source)] .. "%s|r's soul>"
    local name = tooltip:GetName()
    for _, line in ipairs(data.lines) do
        if ReadableTable(line) and Readable(line.type) and line.type == Enum.TooltipDataLineType.UnitOwner
            and Readable(line.lineIndex) and type(line.lineIndex) == "number" then
            local label = name and _G[name .. "TextLeft" .. line.lineIndex]
            if label then SetSoulText(label, text, demonSoul, format); return end
        end
    end
    AddSoulLine(tooltip, text, demonSoul, format)
end

local function SpellEvent(event, unit, castGUID, spellID)
    if not Readable(unit) or not Readable(spellID) then
        -- A restricted stop/success event must not erase a source already captured.
        -- A new unidentified channel cannot safely inherit the old channel's source.
        if event == "UNIT_SPELLCAST_CHANNEL_START" then
            drain = nil
        elseif drain then
            drain.expires = math.min(drain.expires, GetTime()+3)
        end
        pendingAction, recentLoss, sentCast = nil, nil, nil
        lastSpellStatus = "Last restricted event: " .. event .. ": " .. (not Readable(unit) and "unit" or "spell ID") .. "."
        Debug(lastSpellStatus)
        return
    end
    if unit ~= "player" then return end
    local spellName = C_Spell.GetSpellName(spellID)
    if not PlainString(spellName) then return end
    local kind = spellActions[spellName]
    if kind == "drain" then
        if event == "UNIT_SPELLCAST_CHANNEL_START" then
            local source, soul
            if sentCast and PlainString(castGUID) and sentCast.guid == castGUID
                and sentCast.expires >= GetTime() and sentCast.source
                and (sentCast.source ~= UNKNOWN_SOUL or sentCast.soul) then
                source, soul = sentCast.source, sentCast.soul
                lastSourceStatus = sentCast.reason
            else
                source, soul = ReadTargetSoul()
            end
            drain = { source=source, soul=soul, reason=lastSourceStatus,
                castGUID=PlainString(castGUID) and castGUID or nil, expires=GetTime()+20 }
            Debug(lastSourceStatus)
        elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" and drain
            and (not drain.castGUID or not PlainString(castGUID) or drain.castGUID == castGUID) then
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
            stoneSoul = nil
        elseif kind == "imp" then
            -- Imps do not consume a soul shard.
            Shards.demon, pendingDemon = nil, nil
            demonSoul = nil
            pendingAction, recentLoss = nil, nil
        else
            pendingAction = { kind=kind, spell=spellName, target=target, petGUID=petGUID, expires=GetTime()+2 }
            -- A new stone must not inherit an older stone's source if attribution fails.
            if kind == "health" then Shards.healthStoneSrc, healthSoul = UNKNOWN_SOUL, nil end
            if kind == "soul" then Shards.soulStoneSrc, stoneSoul = UNKNOWN_SOUL, nil end
            if kind == "demon" then Shards.demon, pendingDemon, demonSoul = nil, nil, nil end
        end
        if kind == "demon" or kind == "imp" then
            observedDemon, demonRefund, recentGains = nil, nil, {}
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
            healthSoul = nil
        end
    elseif action == "SStone" then
        Shards.soulStoneSrc = source
        stoneSoul = nil
    elseif action == "Smmn" then
        print("ShardSource: " .. sender .. " is summoning you using the soul of " .. SoulName(source) .. ".")
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= addonName then return end
        Shards = type(Shards) == "table" and Shards or {}
        Shards.sources = type(Shards.sources) == "table" and Shards.sources or {}
        loadedSourceStatus = SavedSourceStatus()
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
    elseif event == "PLAYER_LOGOUT" then
        -- Saved variables are written immediately afterward; timers cannot help here.
        Shards.logoutRecovery = RecoverSouls() or "No unresolved names at logout."
        Shards.logoutSources = SavedSourceStatus()
        Shards.logoutRevision = TRACKING_REVISION
    elseif event == "PLAYER_ENTERING_WORLD" then
        drain, pendingAction, recentLoss, sentCast = nil, nil, nil, nil
        pendingDemon = nil
        observedDemon, demonRefund, recentGains, inventoryReady = nil, nil, {}, false
        inventory = {}
        ScanInventory()
        RefreshBags()
        QueueRecovery()
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then
        QueueScan()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        QueueRecovery()
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        demonRefund, recentGains = nil, {}
        QueueScan()
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
        demonRefund, recentGains = nil, {}
        QueueScan()
    elseif event == "UNIT_SPELLCAST_SENT" then
        local unit, target, guid, spellID = ...
        if Readable(unit) and unit == "player" then
            sentCast = nil
            if PlainString(guid) then
                local petGUID = UnitGUID("pet")
                sentCast = { target=PlainString(target) and target or nil, guid=guid, expires=GetTime()+30 }
                -- false means no previous pet; nil means its identity was unavailable.
                if Readable(petGUID) and (petGUID == nil or PlainString(petGUID)) then
                    sentCast.petGUID = petGUID or false
                end
                local spellName = Readable(spellID) and C_Spell.GetSpellName(spellID)
                if PlainString(spellName) and spellActions[spellName] == "drain" then
                    sentCast.source, sentCast.soul = ReadTargetSoul()
                    sentCast.reason = lastSourceStatus
                end
            end
        end
    elseif event == "UNIT_PET" then
        local unit = ...
        if Readable(unit) and unit == "player" then
            BindDemonSource()
            ObserveDemon()
            QueueScan()
        end
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

for _, event in ipairs({"ADDON_LOADED", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "BAG_UPDATE_DELAYED",
    "PLAYER_REGEN_ENABLED", "ADDON_RESTRICTION_STATE_CHANGED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
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
    elseif message == "retry" then
        RecoverSouls()
        RefreshBags()
        print(lastRecoveryStatus)
    elseif message == "status" then
        local version, build, _, interface = GetBuildInfo()
        local count, known, temporary = 0, 0, 0
        for _, entry in pairs(inventory) do
            count = count+1
            if entry.source ~= UNKNOWN_SOUL then
                known = known+1
            elseif entry.soul and entry.soul.hasName then
                temporary = temporary+1
            end
        end
        print("ShardSource " .. addonVersion .. " | WoW " .. version .. " / " .. build .. " / interface " .. interface)
        print("Tracker revision: " .. TRACKING_REVISION)
        print("Shards in bags: " .. count .. "; saved names: " .. known .. "; session-only names: " .. temporary .. ".")
        print("Loaded from disk: " .. loadedSourceStatus .. "; saved table now: " .. SavedSourceStatus() .. ".")
        print(lastSourceStatus)
        print(lastShardStatus)
        print(lastSpellStatus)
        print(lastRecoveryStatus)
        print(lastDisplayStatus)
        if PlainString(Shards.lastRecoveryStatus) then print("Recorded recovery: " .. Shards.lastRecoveryStatus) end
        if PlainString(Shards.logoutRecovery) then print("Last logout: " .. Shards.logoutRecovery) end
        if PlainString(Shards.logoutSources) and PlainString(Shards.logoutRevision) then
            print("At last logout: " .. Shards.logoutSources .. "; tracker " .. Shards.logoutRevision .. ".")
        end
        print("Automatic chat: " .. (ChatAllowed() and "available" or "restricted"))
    elseif message == "testhealth" then
        print("ShardSource: healthstone soul is " .. ColoredSoul(Shards.healthStoneSrc) .. ".")
    elseif message == "testsummon" then
        SendSource("Smmn", "TestUnit", UnitName("player"))
    elseif message == "testsoulstone" then
        SendSource("SStone", Shards.soulStoneSrc, UnitName("player"))
    else
        print("ShardSource: /ssrc status, /ssrc retry, /ssrc emote, /ssrc debug")
    end
end
