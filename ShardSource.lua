local addonname = ...
local f = CreateFrame("Frame")
Shard_Channel = "ShardSrc"
local HSAction = "HStone"
local SMAction = "Smmn"

local SoulShardItemID = 6265
local shardCount = 0
local lastShardKill = "-1"
local lastShardGUID = "-1"
local newShardLoc = ""
local hadShardAt = ""
local bankOpen = 0

local targlvl = 0
local targtype = "normal"

local lastAction = ""
local healthStoneSrc = ""
local soulStoneSrc = ""
local summonPlrSrc = ""
local demonSummoned = ""

-- Trade (Healthstones)
local tradeTarget = ""
local srcAccept = 0
local targAccept = 0
local hasHSInTrade = false

f:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...
    local _ = 0
    if event == "ADDON_LOADED" and arg1 == addonname then
        shardCount = CountShards()
        print("We have " .. shardCount .. " shards")
        Init()
    elseif event == "BAG_UPDATE" then
        UpdateShardList()
        ShowBagColors()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, _, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo()
        if subevent == "UNIT_DIED" and destName == UnitName("target") then
            ctype = strsplit("-", destGUID)
            lastShardKill = destName.."_"..ctype.."_"..targlvl.."_"..targtype
            print("Target died while targeted: " .. lastShardKill)
            UpdateShardList()
        elseif subevent == "SPELL_CAST_SUCCESS" and sourceName == UnitName("player") then
            local timestamp, subevent, _, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, spellID, spellName, spellSchool = CombatLogGetCurrentEventInfo()
            if string.find(spellName, "Create Healthstone") then
                print("Healthstone Created")
                lastAction = "HStone"
                UpdateShardList()
            elseif string.find(spellName, "Summon ") and not string.find(spellName, "Imp") and not string.find(spellName, "Dreadsteed") and not string.find(spellName, "Felsteed") then
                lastAction = "Demon"
                demonSummoned = spellName:gsub("Summon ","")
                UpdateShardList()
            elseif string.find(spellName, "Ritual of Summoning") then
                lastAction = "SummonPlayer"
                summonPlrSrc = UnitName("target")
                UpdateShardList()
            elseif string.find(spellName, "Create Soulstone") then
                lastAction = "SStone"
                UpdateShardList()
            elseif string.find(spellName, "Soulstone Resurrection") then
                local msg = "protected " .. UnitName("target") .. " using the soul of " .. GetNameFromID(soulStoneSrc)
                SendChatMessage(msg, "EMOTE", nil, nil)
                soulStoneSrc = ""
            end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        ChangedTarget()
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = 1
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = 0
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, dtype, sender = ...
		if prefix == Shard_Channel then
            GotMessage(msg, sender)
        end

    -- Trading Healthstone
    elseif event == "TRADE_SHOW" then
        tradeTarget = UnitName("target")
        print("Trade opened with "..tradeTarget)
    elseif event == "TRADE_ACCEPT_UPDATE" then
        srcAccept, targAccept = ...
        CheckForHSTrade(false)
        print("Trade Accept Updated "..srcAccept..", " ..targAccept)
    elseif event == "TRADE_REQUEST_CANCEL" then
        srcAccept = 0
        targAccept = 0
        print("Trade was Cancelled")
    elseif event == "TRADE_CLOSED" then
        if tradeTarget ~= "" and srcAccept == 1 then
            print("Trade Accepted, checking HS was sent")
            CheckForHSTrade(true)
            srcAccept = 0
            targAccept = 0
        else
            print("Trade Finished without success with "..tradeTarget..", "..srcAccept..", " ..targAccept)
        end
	end
end)

local hoverbag=-1
local hoverslot=-1
local hoverbank=0

function Init()
    if not Shards then
        Shards = {}
        Shards.UseEmotes = true;
    end
    Shard_COM_Init()
end

SLASH_SHARDSOURCE1 = "/shardsrc"
SLASH_SHARDSOURCE2 = "/ssrc"
SlashCmdList["SHARDSOURCE"] = function(msg)
    if msg == "testhealth" then
        print("Testing Healthstone Message");
        Shard_COM_SendSource(HSAction,"TestUnit", UnitName("player"))
    elseif msg == "emote" then
        Shards.UseEmotes = not Shards.UseEmotes
        print("Use Shard Emotes: "..tostring(Shards.UseEmotes))
    elseif msg == "testsummon" then
        print("Testing Summon Message");
        Shard_COM_SendSource(SMAction, summonPlrSrc, UnitName("player"))
    end
end

function ChangedTarget()
    targlvl = UnitLevel("target")
    if targlvl == -1 then
        targlvl = -100
    else
        targlvl = targlvl - UnitLevel("player")
    end
    targtype = UnitClassification("target")
end

local function SetShardTooltip(tt)
    local itemName = select(1, tt:GetItem())
    if itemName and itemName == "Soul Shard" then
		SetShardTip(tt)
    elseif itemName and string.find(itemName, "Healthstone") then
        SetStoneTip(tt, true)
    elseif itemName and string.find(itemName, "Soulstone") then
        SetStoneTip(tt, false)
	end
end

function SetShardTip(tooltip)
    local location = getLocationID(hoverbag, hoverslot, hoverbank)
    local text = "Unknown Soul"
    local title = _G[tooltip:GetName().."TextLeft1"]
    local r,g,b = GetItemQualityColor(GetQualityFromID(location))

    if Shards[location] then
        local uid = Shards[location]
        text = GetSoulTextFromKillID(uid)
    end

    title:SetText(text)
    title:SetTextColor(r,g,b)
    tooltip:Show()
end

function SetStoneTip(tooltip, isHealth)
    local srcName = healthStoneSrc;
    if not isHealth then
        srcName = soulStoneSrc
    end
    if not srcName or srcName == "" then
        srcName = "Unknown"
    end

    local lineCount = tooltip:NumLines()
    local title = _G[tooltip:GetName().."TextLeft"..lineCount]
    local r,g,b = GetItemQualityColor(GetQualityFromID(location))

    local text = "Soul of "..GetNameFromID(srcName)..""
    --tooltip:AddLine(text, GetItemQualityColor(GetQualityFromID(srcName)))
    title:SetText(text)
    title:SetTextColor(r,g,b)
end

function GetSoulTextFromKillID(uid)
    local txt = firstUppercase(GetNameFromID(uid)) .. "'s Soul"
    return txt
end

function firstUppercase(s)
    return s:sub(1,1):upper()..s:sub(2)
end

function GetNameFromID(uid)
    local name, type, level, rank = strsplit("_",uid)
    local retText = name
    if type == "Creature" and rank == "normal" then
        retText = "a "..name
    end
    return retText
end

function checkShardsForKill(killedCr)
    lastShardKill = killedCr
end

-- The big one

function UpdateShardList()
    if not Shards then
        Shards = {}
    end

    for bag = 0, NUM_BAG_SLOTS do
        for slot=1,GetContainerNumSlots(bag) do
            CheckShard(bag, slot, 0, GetContainerItemID(bag, slot))
        end
    end

    -- Bank Check
    if bankOpen == 1 then
        -- Bank Window
        for slot=1,GetContainerNumSlots(BANK_CONTAINER) do
            CheckShard(BANK_CONTAINER, slot, 1, GetContainerItemID(BANK_CONTAINER, slot))
        end
        -- Bank Bags
        for bag = NUM_BAG_SLOTS+1, NUM_BAG_SLOTS+NUM_BANKBAGSLOTS do
            for slot=1,GetContainerNumSlots(bag) do
                CheckShard(bag, slot, 1, GetContainerItemID(bag, slot))
            end
        end
    end

    ShardProcess()
end

function ShardProcess()

    -- We have a new Soul Shard - save the info!
    if newShardLoc ~= "" then
        if lastShardKill ~= "-1" then
            --print("Had recent kill, assuming Shard is from " .. lastShardKill .. " : setting ID at " .. newShardLoc)
            Shards[newShardLoc] = lastShardKill
            lastShardKill = "-1"

        -- Shard moved in bag (one new and one lost), just update its position
        elseif hadShardAt ~= "" then
            --print("Shard Moved from " .. hadShardAt .. " to " .. newShardLoc)
            Shards[newShardLoc] = Shards[hadShardAt]
        end
    end

    -- Missing a Shard and we have the info, what did we do with it?
    if hadShardAt ~= "" then
        local shardSrc = Shards[hadShardAt]

        -- Created a Healthstone
        if lastAction == "HStone" then
            print("Healthstone created from " .. shardSrc)
            healthStoneSrc = shardSrc
            lastAction = ""

        -- Created a Soulstone
        elseif lastAction == "SStone" then
            print("Soulstone created from " .. shardSrc)
            soulStoneSrc = shardSrc
            lastAction = ""

        -- Summoned a Demon
        elseif lastAction == "Demon" then
            print("Demon summoned from " .. shardSrc)
            local msg = "summoned a " .. demonSummoned .. " using the soul of " .. GetNameFromID(shardSrc)
            SendChatMessage(msg, "EMOTE", nil, nil)
            demonSummoned = ""
            lastAction = ""

        -- Summoned a Player
        elseif lastAction == "SummonPlayer" then
            print(summonPlrSrc.." summoned from " .. shardSrc)
            local msg = "summoned " .. summonPlrSrc .. " using the soul of " .. GetNameFromID(shardSrc)
            SendChatMessage(msg, "EMOTE", nil, nil)
            Shard_COM_SendSource(SMAction, shardSrc, UnitName("player"))
            summonPlrSrc = ""
            lastAction = ""

        end
        Shards[hadShardAt] = nil
    end

    newShardLoc = ""
    hadShardAt = ""
    shardCount = CountShards()
end

function CheckShard(bag, slot, bank, itemid)
    local locationID = getLocationID(bag, slot, bank)
    local isShard = (itemid == SoulShardItemID)

    if not Shards[locationID] and isShard then
        --No Shard Registered to this location but we have a shard
        --print("Found a new shard in our bag: " .. locationID)
        newShardLoc = locationID
    elseif Shards[locationID] and not isShard then
        -- We used to have a shard here, now it's missing!
        --print("We're missing a shard!")
        hadShardAt = locationID
    end
end

function getLocationID(bag, slot, bank)
    return bag.."x"..slot.."x"..bank
end
-- Utility

function CountShards()
    local numShardsTotal = 0
    for bag=0,4 do
        for slot=1,GetContainerNumSlots(bag) do
            if GetContainerItemID(bag, slot) == SoulShardItemID then
                numShardsTotal = numShardsTotal+1
            end
        end
    end
    return numShardsTotal
end

function ShowBagColors()
    if bankOpen == 1 then
        for slot=1,GetContainerNumSlots(BANK_CONTAINER) do
            if GetContainerItemID(BANK_CONTAINER, slot) == SoulShardItemID then
                SetBagItemGlow(BANK_CONTAINER, slot, 0)
            end
        end
    end
    local maxBags = NUM_BAG_SLOTS
    if(bankOpen) then maxBags = NUM_BAG_SLOTS+NUM_BANKBAGSLOTS end
    for bag=0,maxBags do
        for slot=1,GetContainerNumSlots(bag) do
            if GetContainerItemID(bag, slot) == SoulShardItemID then
                SetBagItemGlow(bag, slot, 0)
            end
        end
    end
end

function GetQualityFromID(location)

    if not Shards[location] then
        return GetItemQualityColor(1)
    end

    local level, rank, type = 0
    local uid = Shards[location]
    local name, type, level, rank = strsplit("_",uid)
    if type == "Creature" then
        if level == -100 or rank == "worldboss" then
            return LE_ITEM_QUALITY_LEGENDARY
        elseif tonumber(level) >= -3 then
            if rank == "elite" or rank == "rareelite" then
                return LE_ITEM_QUALITY_UNCOMMON
            else
                return LE_ITEM_QUALITY_COMMON
            end
        else
            return LE_ITEM_QUALITY_POOR
        end
    elseif type == "Player" then
        if level == -100 then
            return LE_ITEM_QUALITY_ARTIFACT
        elseif tonumber(level) >= 0 then
            return LE_ITEM_QUALITY_EPIC
        else
            return LE_ITEM_QUALITY_RARE
        end
    else
        return LE_ITEM_QUALITY_COMMON
    end
end

function SetBagItemGlow(bagId, slot, bank)
	local item = nil
    local locationid = getLocationID(bagId, slot, bank)

	if IsAddOnLoaded("OneBag3") then
		item = _G["OneBagFrameBag"..bagId.."Item"..slot]
	else
		for i = 1, NUM_CONTAINER_FRAMES, 1 do
			local frame = _G["ContainerFrame"..i]
			if frame:GetID() == bagId and frame:IsShown() then
				item = _G["ContainerFrame"..i.."Item"..(GetContainerNumSlots(bagId) + 1 - slot)]
			end
		end
	end
    if bagId and bank and bankOpen == 1 and bagId == BANK_CONTAINER then
        -- Bank Frame Items don't have ability to set color?
        -- item = _G["BankFrameItem"..(GetContainerNumSlots(BANK_CONTAINER) + 1 - slot)]
    end
	if item then
        local color = NEW_ITEM_ATLAS_BY_QUALITY[GetQualityFromID(locationid)]
		item.NewItemTexture:SetAtlas(color)
		item.NewItemTexture:Show()
		item.newitemglowAnim:Play()
        item.newitemglowAnim:Pause()
	end
end

local bagOpenedBefore = false

function CheckBagOpenChanged()
    if ContainerFrame1:IsVisible() and not bagOpenedBefore then
        bagOpenedBefore = true
        ShowBagColors()
    elseif bagOpenedBefore and not ContainerFrame1:IsVisible() then
        bagOpenedBefore = false
    end
end

-- Communication System


function Shard_COM_Init()
    C_ChatInfo.RegisterAddonMessagePrefix(Shard_Channel)
    C_ChatInfo.IsAddonMessagePrefixRegistered(Shard_Channel)
end

function Shard_COM_SendSource(action, Src, UnitName)
    print("Attempting Src Send to "..UnitName.." of: "..Src)
    if Shard_IsValidName(UnitName) then
        C_ChatInfo.SendAddonMessage(Shard_Channel, action..":"..Src, "WHISPER", UnitName)
    end
end

function GotMessage(msg, sender)
    print("Got ShardMsg " .. msg)
    itype, unit = strsplit(":", msg)
    if itype and itype == HSAction then
        healthStoneSrc = unit
        print("Healthstone Source: " .. healthStoneSrc)
    elseif itype and itype == SMAction then
        print("You have been by "..sender.." using the soul of " .. GetNameFromID(unit))
    end
end

function Shard_IsValidName(UnitName)
    return UnitName ~= _G["UNKNOWN"] and UnitName ~= _G["UNKNOWNOBJECT"]
end

function CheckForHSTrade(isComplete)
    if isComplete then
        if hasHSInTrade then
            print("Healthstone Traded - telling "..tradeTarget.." that it came from "..healthStoneSrc)
            Shard_COM_SendSource(HSAction, tradeTarget, healthStoneSrc)
            healthStoneSrc = ""
        else
            print("No Healthstone found in successful trade, ignoring...")
        end
    else
        hasHSInTrade = false
        for index=1,7 do
            local name = GetTradePlayerItemInfo(index)
            if name and string.find(name, "Healthstone") then
                hasHSInTrade = true
                print("Found a Healthstone in trade window!")
                return
            end
        end
        if not hasHSInTrade then
            print("Trade Status updated with no Healthstone")
        end
    end
end

hooksecurefunc("ContainerFrameItemButton_OnEnter", function(self)
    SetCursorPos(self)
end)

-- Theres gotta be a better way...
function CheckBankHover()
    for slot=1,GetContainerNumSlots(BANK_CONTAINER) do
        local slotFrame = _G["BankFrameItem"..(GetContainerNumSlots(BANK_CONTAINER) + 1 - slot)]
        if slotFrame and MouseIsOver(slotFrame) then
            SetCursorPos(slotFrame)
            return
        end
    end
end

function SetCursorPos(self)
    hoverbag = self:GetParent():GetID()
    hoverslot = self:GetID()
    hoverbank = 0
    if hoverbag == BANK_CONTAINER or hoverbag > NUM_BAG_SLOTS then
        hoverbank = 1
    end
    ShowBagColors()
end

function ShardSource_OnUpdate()
    CheckBagOpenChanged()
    if bankOpen == 1 then
        CheckBankHover()
    end
end

GameTooltip:HookScript("OnTooltipSetItem", SetShardTooltip)
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("TRADE_SHOW")
f:RegisterEvent("TRADE_ACCEPT_UPDATE")
f:RegisterEvent("TRADE_CLOSED")
f:RegisterEvent("TRADE_REQUEST_CANCEL")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("BANKFRAME_OPENED")
f:RegisterEvent("BANKFRAME_CLOSED")
f:RegisterEvent("CHAT_MSG_ADDON")
print("[ShardSource] by Blueteak loaded.")
