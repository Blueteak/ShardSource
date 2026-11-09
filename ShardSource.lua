local addonName = ...
local addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version")
if not addonVersion or addonVersion:find("@", 1, true) then addonVersion = "development" end
local TRACKING_REVISION = "2026-11-08.2"
local frame = CreateFrame("Frame")
local SHARD_ID, PREFIX, UNKNOWN_SOUL = 6265, "ShardSrc", "Unknown"
local ready, bankOpen, scanQueued = false, false, false
local inventory, drain, pendingAction, recentLoss, sentCast = {}, nil, nil, nil, nil
local trade, lastTrade = nil, nil
local pendingDemon
local nextOutdoorEmote = 0
local observedDemon, demonRefund
local recentGains, inventoryReady = {}, false
local REFUND_WINDOW = 3
local lastSourceStatus = "No Drain Soul observed yet."
local lastShardStatus = "No new shard observed yet."
local lastSpellStatus = "No restricted spell events observed."
-- Shared pending replies follow shards into stones, demons, and returned shards.
local sessionSouls, healthSoul, stoneSoul, demonSoul = {}, nil, nil, nil
local whisperRefreshQueued = false
local loadedSourceStatus
local chatProbe, chatProbeExpires
local whisperRequests, whisperSequence = {}, 0
local whisperLines, targetRevision = {}, 0
local ReceiveSoulWhisper
local lastWhisperStatus = "No soul-name self-whisper attempted."
local spellActions = {}
local demonTypes = {}
local hookedContainers = setmetatable({}, { __mode = "k" })

local healthstones = { [5512]=true, [5511]=true, [5509]=true, [5510]=true, [9421]=true,
    [22103]=true, [22104]=true, [22105]=true }
for id = 19004, 19013 do healthstones[id] = true end
local soulstones = { [5232]=true, [16892]=true, [16893]=true, [16895]=true,
    [16896]=true, [22116]=true }
local colors = { [0]="9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000", "e6cc80" }

-- Check restricted API values before reading them.
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

local function IdentityState(value)
    if not Readable(value) then return "secret" end
    return PlainString(value) and "readable" or "missing"
end

local function PlayerWhisperName()
    if not GetUnitName then return end
    local ok, name = pcall(GetUnitName, "player", true)
    if ok and ValidSoulName(name) then return name end
end

local function FilterSoulWhisper(_, _, text, sender, ...)
    if not PlainString(text) then return false end
    if not text:match("^SSRC%-SOUL:[^:]+:%d+:") and not text:match("^SSRC:") then return false end
    local guid, playerGUID = select(10, ...), UnitGUID("player")
    if PlainString(guid) and PlainString(playerGUID) and guid == playerGUID then return true end
    local playerName = PlayerWhisperName()
    return PlainString(sender) and playerName ~= nil and sender == playerName
end

local function RequestSoulWhisper(soul)
    if soul.whisperRequested then return end
    soul.whisperRequested = true
    if soul.targetRevision ~= targetRevision then
        lastWhisperStatus = "Soul-name whisper skipped: target changed before the name request."
        return
    end
    local recipient, playerGUID = PlayerWhisperName(), UnitGUID("player")
    if not recipient or not PlainString(playerGUID) then
        lastWhisperStatus = "Soul-name whisper skipped: full player identity unavailable."
        return
    end
    -- Request at channel start, before death or target clearing can precede the shard.
    -- Never retry against a different target; let the client decide whether chat is allowed.
    whisperSequence = whisperSequence+1
    local token = tostring(GetTime()) .. ":" .. whisperSequence
    local request = { soul=soul, playerGUID=playerGUID }
    whisperRequests[token] = request
    lastWhisperStatus = "Soul-name self-whisper requested."
    local ok = pcall(C_ChatInfo.SendChatMessage, "SSRC-SOUL:" .. token .. ":%t", "WHISPER", nil, recipient)
    if not ok then
        whisperRequests[token] = nil
        lastWhisperStatus = "Soul-name self-whisper rejected by the client."
    else
        C_Timer.After(60, function()
            if whisperRequests[token] == request then
                whisperRequests[token] = nil
                lastWhisperStatus = "Soul-name self-whisper timed out without a readable reply."
                Debug(lastWhisperStatus)
            end
        end)
    end
    Debug(lastWhisperStatus)
end

local function ArmChatProbe()
    local ok = pcall(frame.RegisterEvent, frame, "CHAT_MSG_WHISPER")
    if not ok then
        print("ShardSource: the client rejected whisper event registration.")
        return false
    end
    chatProbe, chatProbeExpires = nil, GetTime()+60
    return true
end

local function ReportChatProbe()
    if not chatProbe then
        print("ShardSource: no whisper captured. Use /ssrc chatprobe arm, then whisper yourself SSRC:%t.")
        return
    end
    local lockdown = "unavailable"
    if C_ChatInfo.InChatMessagingLockdown then
        local ok, value = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and Readable(value) then lockdown = value and "active" or "inactive" end
    end
    print("ShardSource chat probe: chat lockdown=" .. lockdown .. ".")
    print("At capture: message=" .. chatProbe.messageState .. "; line ID=" .. chatProbe.lineState .. ".")
    if not chatProbe.lineID then
        print("Fresh chat lookup: no readable line ID to query.")
    elseif not C_ChatInfo.GetChatLineText then
        print("Fresh chat lookup: API unavailable.")
    else
        local ok, text = pcall(C_ChatInfo.GetChatLineText, chatProbe.lineID)
        print("Fresh chat lookup: " .. (ok and IdentityState(text) or "lookup error") .. ".")
        if ok and PlainString(text) then
            -- Only print ordinary text; never pass a secret to Lua string operations.
            print("Retrieved text: " .. text:gsub("|", "||"):sub(1, 300))
        end
    end
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
            quality=Quality(UNKNOWN_SOUL .. "_" .. details), targetRevision=targetRevision }
        lastSourceStatus = "Drain Soul name unavailable; awaiting a self-whisper at channel start."
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
    for id, demonType in pairs({ [697]="Voidwalker", [712]="Succubus", [691]="Felhunter", [30146]="Felguard" }) do
        local name = C_Spell.GetSpellName(id)
        if PlainString(name) then demonTypes[name] = demonType end
    end
end

local function OutdoorSummonEmote(kind, spell, target)
    if not Shards.UseEmotes or not ChatAllowed() or GetTime() < nextOutdoorEmote then return end
    -- Predict only the announcement. Actual consumption still determines saved sources.
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if Readable(itemID) and itemID == SHARD_ID then
                local guid = ItemGUID(bag, slot)
                local source = guid and RecordedSource(Shards.sources[guid], sessionSouls[guid]) or UNKNOWN_SOUL
                nextOutdoorEmote = GetTime()+10
                if kind == "summon" then
                    Emote("begins summoning " .. (target or "a player") .. " using the soul of " .. SoulName(source) .. ".")
                else
                    Emote("begins summoning a " .. (demonTypes[spell] or "demon") .. " using the soul of " .. SoulName(source) .. ".")
                end
                return
            end
        end
    end
end

local function SummonAbilityPressed(spellID)
    if not ready or not Readable(spellID) or type(spellID) ~= "number" or IsInInstance() then return end
    local spell = C_Spell.GetSpellName(spellID)
    if not PlainString(spell) then return end
    local kind = spellActions[spell]
    if kind ~= "demon" and kind ~= "summon" then return end
    local target = kind == "summon" and GetUnitName("target", true)
    -- Send synchronously from the action press. Events and timers lose its
    -- hardware-input context. The shared cooldown also deduplicates nested hooks.
    OutdoorSummonEmote(kind, spell, PlainString(target) and target or nil)
end

if UseAction then
    hooksecurefunc("UseAction", function(slot)
        if not ready or not Readable(slot) or type(slot) ~= "number" then return end
        local spellID = C_ActionBar and C_ActionBar.GetSpell and C_ActionBar.GetSpell(slot)
        if Readable(spellID) and type(spellID) == "number" then
            SummonAbilityPressed(spellID)
            return
        end
        local actionType, id = GetActionInfo(slot)
        if not PlainString(actionType) or not Readable(id) or type(id) ~= "number" then return end
        if actionType == "spell" then
            SummonAbilityPressed(id)
        elseif actionType == "macro" and GetMacroSpell then
            SummonAbilityPressed(GetMacroSpell(id))
        end
    end)
end
if CastSpellByID then hooksecurefunc("CastSpellByID", SummonAbilityPressed) end
if C_Spell.CastSpell then hooksecurefunc(C_Spell, "CastSpell", SummonAbilityPressed) end

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
        if not action.startEmote then
            Emote("used the soul of " .. SoulName(source) .. " to cast " .. action.spell .. ".")
        end
    elseif action.kind == "summon" then
        if not action.startEmote then
            Emote("began summoning " .. (action.target or "a player") .. " using the soul of " .. SoulName(source) .. ".")
        end
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
        lastShardStatus = soul and source == UNKNOWN_SOUL and "Returned shard kept the demon's pending whisper record."
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
                        if not isBank and not bankOpen and not GetCursorInfo() and drain and drain.expires >= GetTime() then
                            source = RecordedSource(drain.source, drain.soul)
                            sessionSouls[guid] = drain.soul
                            lastShardStatus = drain.soul and source == UNKNOWN_SOUL
                                and "New shard matched to Drain Soul; pending whisper record attached."
                                or source == UNKNOWN_SOUL
                                and "New shard matched to Drain Soul, but " .. drain.reason
                                or "New shard matched to Drain Soul: " .. SoulName(source)
                            -- Multiple shards can arrive in one update or later in
                            -- the same channel. Keep their shared source until expiry.
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

local function ResolveSoulWhispers()
    -- Combat can restrict the whisper event even after the send succeeds. Retain
    -- readable line IDs and re-read both text and sender when restrictions lift.
    for lineID, expires in pairs(whisperLines) do
        if expires < GetTime() then
            whisperLines[lineID] = nil
        elseif C_ChatInfo.GetChatLineText and C_ChatInfo.GetChatLineSenderGUID then
            local textOK, text = pcall(C_ChatInfo.GetChatLineText, lineID)
            local senderOK, sender = pcall(C_ChatInfo.GetChatLineSenderGUID, lineID)
            if textOK and senderOK and PlainString(text) and PlainString(sender) then
                ReceiveSoulWhisper(text, sender, true)
                whisperLines[lineID] = nil
            end
        end
    end
    local function UpdateEntry(entry)
        if entry then
            entry.source = RecordedSource(entry.source, entry.soul)
        end
    end
    for guid, soul in pairs(sessionSouls) do
        local source = RecordedSource(Shards.sources[guid], soul)
        if PlainString(source) and source ~= UNKNOWN_SOUL then
            Shards.sources[guid] = source
        end
        UpdateEntry(inventory[guid])
    end
    Shards.healthStoneSrc = RecordedSource(Shards.healthStoneSrc, healthSoul)
    Shards.soulStoneSrc = RecordedSource(Shards.soulStoneSrc, stoneSoul)
    if Shards.demon then Shards.demon.source = RecordedSource(Shards.demon.source, demonSoul) end
    for _, entry in pairs({pendingDemon, observedDemon, demonRefund, recentLoss, drain, sentCast}) do
        UpdateEntry(entry)
    end
end

ReceiveSoulWhisper = function(text, senderGUID, deferRefresh)
    if not PlainString(text) or not PlainString(senderGUID) then return false end
    local stamp, sequence, name = text:match("^SSRC%-SOUL:([^:]+):(%d+):(.+)$")
    if not stamp then return false end
    local token = stamp .. ":" .. sequence
    local request = whisperRequests[token]
    if not request or senderGUID ~= request.playerGUID then return false end
    whisperRequests[token] = nil
    if not ValidSoulName(name) or name == UNKNOWN_SOUL or name:find("%%t") or name:find("[|\r\n]") then
        lastWhisperStatus = "Soul-name whisper returned no usable expanded name."
        return true
    end
    local soul = request.soul
    if soul.source == UNKNOWN_SOUL then
        soul.source = name:gsub("[_:]", "") .. "_" .. soul.details
        -- The same soul object follows the shard into stones/demons, so replies
        -- arriving before or after the bag update resolve the original capture.
        if not deferRefresh then
            ResolveSoulWhispers()
            RefreshBags()
        end
    end
    lastWhisperStatus = "Soul-name self-whisper recovered: " .. SoulName(soul.source)
    Debug(lastWhisperStatus)
    return true
end

local function QueueWhisperRefresh()
    if whisperRefreshQueued or not ready then return end
    whisperRefreshQueued = true
    -- Restriction changes are announced before activation/after deactivation.
    -- Let the event finish before trying the lookup, including on zone changes.
    C_Timer.After(0.5, function()
        whisperRefreshQueued = false
        ResolveSoulWhispers()
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
        QueueWhisperRefresh()
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
            title:SetText(text:sub(1, 1):upper() .. text:sub(2))
            local r, g, b = C_Item.GetItemQualityColor(soul and soul.quality or Quality(source))
            title:SetTextColor(r, g, b)
        else
            tooltip:AddLine(text, 1, 1, 1)
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
        tooltip:AddLine("Soul of " .. ColoredSoul(source), 1, 1, 1)
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
            if soul and source == UNKNOWN_SOUL then RequestSoulWhisper(soul) end
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
            -- Outdoors only the input hooks may announce, including when throttled.
            pendingAction.startEmote = (kind == "demon" or kind == "summon")
                and (not IsInInstance() or (sentCast and sentCast.startEmote))
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
        -- Retire legacy creature-identity recovery without touching saved names.
        Shards.pendingSources, Shards.lastRecoveryStatus, Shards.logoutRecovery = nil, nil, nil
        loadedSourceStatus = SavedSourceStatus()
        if Shards.UseEmotes == nil then Shards.UseEmotes = true end
        Shards.healthStoneSrc = PlainString(Shards.healthStoneSrc) and Shards.healthStoneSrc or UNKNOWN_SOUL
        Shards.soulStoneSrc = PlainString(Shards.soulStoneSrc) and Shards.soulStoneSrc or UNKNOWN_SOUL
        if not ReadableTable(Shards.demon) or not PlainString(Shards.demon.guid)
            or not PlainString(Shards.demon.source) then Shards.demon = nil end
        Shards.schemaVersion = 2
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        local addFilter = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter or ChatFrame_AddMessageEventFilter
        if addFilter then
            -- Display filters do not suppress the addon's event handler. Match
            -- only our marked self-whispers, even after a request has resolved.
            addFilter("CHAT_MSG_WHISPER", FilterSoulWhisper)
            addFilter("CHAT_MSG_WHISPER_INFORM", FilterSoulWhisper)
        end
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, ItemTooltip)
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, DemonTooltip)
        InitSpells()
        ready = true
        print("Loaded |cffa335ee[ShardSource]|r " .. addonVersion .. " for WoW Forever.")
    elseif not ready then
        return
    elseif event == "PLAYER_LOGOUT" then
        -- Saved variables are written immediately afterward; timers cannot help here.
        ResolveSoulWhispers()
        Shards.logoutSources = SavedSourceStatus()
        Shards.logoutRevision = TRACKING_REVISION
    elseif event == "PLAYER_ENTERING_WORLD" then
        targetRevision = targetRevision+1
        drain, pendingAction, recentLoss, sentCast = nil, nil, nil, nil
        pendingDemon = nil
        observedDemon, demonRefund, recentGains, inventoryReady = nil, nil, {}, false
        inventory = {}
        ScanInventory()
        RefreshBags()
        QueueWhisperRefresh()
    elseif event == "PLAYER_TARGET_CHANGED" then
        targetRevision = targetRevision+1
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then
        QueueScan()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        QueueWhisperRefresh()
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
                sentCast = { target=PlainString(target) and target or nil, guid=guid,
                    expires=GetTime()+30, startEmote=not IsInInstance() }
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
    elseif event == "CHAT_MSG_WHISPER" then
        local text = ...
        if ReceiveSoulWhisper(text, select(12, ...)) then return end
        local lineID = select(11, ...)
        if next(whisperRequests) and Readable(lineID) and type(lineID) == "number"
            and (not Readable(text) or not Readable(select(12, ...))) then
            local count = 0
            for _ in pairs(whisperLines) do count = count+1 end
            if count < 32 then whisperLines[lineID] = GetTime()+60 end
            lastWhisperStatus = "Soul-name whisper received restricted; waiting to re-read chat history."
        end
        if not chatProbeExpires then return end
        local expires = chatProbeExpires
        chatProbeExpires = nil
        if GetTime() > expires then
            print("ShardSource: chat probe expired. Use /ssrc chatprobe arm to try again.")
            return
        end
        local lineState = not Readable(lineID) and "secret"
            or type(lineID) == "number" and "readable" or "missing"
        chatProbe = { messageState=IdentityState(text), lineState=lineState,
            lineID=lineState == "readable" and lineID or nil }
        if PlainString(text) then print("Captured text: " .. text:gsub("|", "||"):sub(1, 300)) end
        ReportChatProbe()
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
    "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED", "ADDON_RESTRICTION_STATE_CHANGED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "CHAT_MSG_ADDON", "CHAT_MSG_WHISPER", "TRADE_SHOW", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_ACCEPT_UPDATE",
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
        ResolveSoulWhispers()
        RefreshBags()
        print(lastWhisperStatus)
    elseif message == "chatprobe arm" then
        if ArmChatProbe() then
            print("ShardSource: next incoming whisper will be captured for this probe. Send yourself SSRC:%t within 60 seconds.")
        end
    elseif message == "chatprobe cancel" then
        chatProbe, chatProbeExpires = nil, nil
        print("ShardSource: chat probe cleared.")
    elseif message == "chatprobe" then
        ReportChatProbe()
    elseif message == "probe" then
        local name, guid = UnitName("target"), UnitGUID("target")
        local nameState, guidState = IdentityState(name), IdentityState(guid)
        local lookupState = "not attempted"
        if guidState ~= "missing" and UnitNameFromGUID then
            local ok, freshName = pcall(UnitNameFromGUID, guid)
            lookupState = ok and IdentityState(freshName) or "lookup error"
        end
        print("ShardSource target probe " .. TRACKING_REVISION .. ": "
            .. (InCombatLockdown() and "in combat" or "out of combat") .. ".")
        print("Target name=" .. nameState .. "; target GUID=" .. guidState
            .. "; GUID lookup name=" .. lookupState .. ".")
        local creatureState = "API unavailable"
        if UnitCreatureID then
            local ok, id = pcall(UnitCreatureID, "target")
            if not ok then creatureState = "lookup error"
            elseif not Readable(id) then creatureState = "secret"
            elseif type(id) == "number" then creatureState = "readable: " .. id
            else creatureState = "missing" end
        end
        print("UnitCreatureID=" .. creatureState .. ".")
        local tooltipState = "API unavailable"
        if C_TooltipInfo and C_TooltipInfo.GetUnit then
            local ok, result = pcall(function()
                local data = C_TooltipInfo.GetUnit("target")
                if not Readable(data) then return "data=secret" end
                if not ReadableTable(data) then return "data=missing or inaccessible" end
                local titleState = "missing"
                if not Readable(data.lines) then titleState = "secret lines"
                elseif ReadableTable(data.lines) then
                    local line = data.lines[1]
                    if not Readable(line) then titleState = "secret line"
                    elseif ReadableTable(line) then titleState = IdentityState(line.leftText) end
                end
                local freshState = "not attempted"
                local tooltipGUIDState = IdentityState(data.guid)
                if tooltipGUIDState ~= "missing" and UnitNameFromGUID then
                    local lookupOK, freshName = pcall(UnitNameFromGUID, data.guid)
                    freshState = lookupOK and IdentityState(freshName) or "lookup error"
                end
                return "GUID=" .. tooltipGUIDState .. "; title=" .. titleState
                    .. "; GUID lookup name=" .. freshState
            end)
            tooltipState = ok and result or "lookup/read error"
        end
        print("Target tooltip: " .. tooltipState .. ".")
        -- Forever's UnitName can omit the surname. Use the full-name UI helper.
        local recipient = PlayerWhisperName()
        if nameState == "missing" and guidState == "missing" then
            print("ShardSource: select a target before testing the self-whisper.")
        elseif not PlainString(recipient) then
            print("ShardSource: self-whisper skipped; full player name unavailable.")
        elseif not ChatAllowed() then
            print("ShardSource: self-whisper skipped; addon chat is restricted or you are in combat.")
        elseif ArmChatProbe() then
            print("ShardSource: requesting self-whisper SSRC:%t to " .. recipient .. " through the addon API.")
            local ok = pcall(C_ChatInfo.SendChatMessage, "SSRC:%t", "WHISPER", nil, recipient)
            if not ok then
                chatProbeExpires = nil
                print("ShardSource: the client rejected the addon self-whisper. Manual /ssrc chatprobe arm remains available.")
            end
        end
    elseif message == "status" then
        local count, known, pending = 0, 0, 0
        for _ in pairs(whisperRequests) do pending = pending+1 end
        for _, entry in pairs(inventory) do
            count = count+1
            if entry.source ~= UNKNOWN_SOUL then known = known+1 end
        end
        print("ShardSource tracker " .. TRACKING_REVISION)
        print("Shards in bags: " .. count .. "; saved names: " .. known .. "; unknown: " .. (count-known) .. ".")
        print("Loaded from disk: " .. loadedSourceStatus .. "; saved table now: " .. SavedSourceStatus() .. ".")
        print("Pending self-whispers: " .. pending .. ".")
        print(lastShardStatus)
        print(lastWhisperStatus)
    elseif message == "testhealth" then
        print("ShardSource: healthstone soul is " .. ColoredSoul(Shards.healthStoneSrc) .. ".")
    elseif message == "testsummon" then
        SendSource("Smmn", "TestUnit", UnitName("player"))
    elseif message == "testsoulstone" then
        SendSource("SStone", Shards.soulStoneSrc, UnitName("player"))
    else
        print("ShardSource: /ssrc status, /ssrc probe, /ssrc chatprobe [arm/cancel], /ssrc retry, /ssrc emote, /ssrc debug")
    end
end
