local addonname = ...
local f = CreateFrame("Frame")
Shard_Channel = "ShardSrc"
local HSAction = "HStone"
local SMAction = "Smmn"
local SSAction = "SStone"

local SoulShardItemID = 6265
local shardCount = 0
local lastShardKill = "-1"
local lastShardGUID = "-1"
local newShardLoc = ""
local hadShardAt = ""
local bankOpen = 0

local targlvl = 0
local levelDelta = 0
local targtype = "normal"
local targetCanGiveXP = false

local lastAction = ""
local summonPlrSrc = ""
local demonSummoned = ""

-- Trade (Healthstones)
local tradeTarget = ""
local srcAccept = 0
local targAccept = 0
local hasHSInTrade = false

-- Colors
POOR =0
COMMON =1
UNCOMMON =2
RARE =3
EPIC =4
LEGENDARY =5
ARTIFACT =6
HEIRLOOM =7

local rarityColors = {
    inline={
        [POOR] ="9d9d9d",
        [COMMON] ="ffffff",
        [UNCOMMON] ="1eff00",
        [RARE] ="0070dd",
        [EPIC] ="a335ee",
        [LEGENDARY] ="ff8000",
        [ARTIFACT] ="e6cc80",
        [HEIRLOOM] ="00ccff",
        "",
    }
}

f:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...
    local _ = 0
    if event == "ADDON_LOADED" and arg1 == addonname then
        shardCount = CountShards()
        DebugLog("We have " .. shardCount .. " shards")
        Init()
    elseif event == "BAG_UPDATE" then
        UpdateShardList()
        ShowBagColors()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, _, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo()
        local fname = strsplit("-", destName)
        if(subevent == "UNIT_SPELLCAST_SUCCEEDED") then
            DebugLog("Cast Occurred: "..sourceName.." - "..UnitName("player"))
        end
        if subevent == "UNIT_DIED" and fname == UnitName("target") and targetCanGiveXP then
            ctype = strsplit("-", destGUID)
            lastShardKill = fname.."_"..ctype.."_"..levelDelta.."_"..targtype.."_"..targlvl
            DebugLog("Target died while targeted: " .. lastShardKill)
            UpdateShardList()
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
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local castTarget, castGUID, spellid = ...
        local spellName = GetSpellInfo(spellid)
        if castTarget == "player" then
            if string.find(spellName, "Create Healthstone") then
                DebugLog("Healthstone Created")
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
                local msg = ""
                if UnitName("target") then
                    msg = "protected " .. UnitName("target") .. " using the soul of " .. GetNameFromID(Shards.soulStoneSrc).."."
                else
                    msg = "is now protected by the soul of " .. GetNameFromID(Shards.soulStoneSrc).."."
                end
                SendChatMessage(msg, "EMOTE", nil, nil)
                Shards.soulStoneSrc = ""
            end
        end

    -- Trading Healthstone
    elseif event == "TRADE_SHOW" then
        tradeTarget = TradeFrameRecipientNameText:GetText()
        --DebugLog("Trade opened with "..tradeTarget)
    elseif event == "TRADE_ACCEPT_UPDATE" then
        srcAccept, targAccept = ...
        CheckForHSTrade(false)
        --DebugLog("Trade Accept Updated "..srcAccept..", " ..targAccept)
    elseif event == "TRADE_REQUEST_CANCEL" then
        srcAccept = 0
        targAccept = 0
        --DebugLog("Trade was Cancelled")
    elseif event == "TRADE_CLOSED" then
        if tradeTarget ~= "" and srcAccept == 1 then
            --DebugLog("Trade Accepted, checking HS was sent")
            CheckForHSTrade(true)
            srcAccept = 0
            targAccept = 0
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
        Shards.healthStoneSrc = "";
        Shards.soulStoneSrc = "";
        Shards.debug = false
    end
    Shard_COM_Init()
end

SLASH_SHARDSOURCE1 = "/shardsrc"
SLASH_SHARDSOURCE2 = "/ssrc"
SlashCmdList["SHARDSOURCE"] = function(msg)
    if msg == "testhealth" then
        DebugLog("Testing Healthstone Message");
        Shard_COM_SendSource(HSAction,"TestUnit", UnitName("player"))
    elseif msg == "emote" then
        Shards.UseEmotes = not Shards.UseEmotes
        print("Use Shard Emotes: "..tostring(Shards.UseEmotes))
    elseif msg == "testsummon" then
        DebugLog("Testing Summon Message");
        Shard_COM_SendSource(SMAction, summonPlrSrc, UnitName("player"))
    elseif msg == "testsoulstone" then
        DebugLog("Testing Soulstone Message");
        Shard_COM_SendSource(SSAction, Shards.soulStoneSrc, UnitName("player"))
    elseif msg == "debug" then
        Shards.debug = not Shards.debug
        print("Debug Mode: "..tostring(Shards.UseEmotes))
    end
end

function ChangedTarget()
    targlvl = UnitLevel("target")
    if targlvl == -1 then
        levelDelta = -100
    else
        levelDelta = targlvl - UnitLevel("player")
    end
    if UnitIsPlayer("target") then
        local _ = ""
        _, targtype = UnitClass("target")
    else
       targtype = UnitClassification("target")
    end

    targetCanGiveXP = true;
    if targlvl > 0 then
        targetCanGiveXP = levelDelta > -GetQuestGreenRange()
    end

end

local function SetTooltip(tt)
    local itemName = select(1, tt:GetItem())
    if itemName and itemName == "Soul Shard" then
		SetShardTip(tt)
    elseif itemName and string.find(itemName, "Healthstone") then -- Healthstone
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
    local detail = ""

    if Shards[location] then
        local uid = Shards[location]
        text = GetSoulTextFromKillID(uid)
        detail = GetDetail(Shards[location])
    end

    title:SetText(text)
    title:SetTextColor(r,g,b)

    if detail and detail ~= "" then
        local det = "["..detail.."]"
        tooltip:AddLine(det)
    end

    tooltip:Show()
end

function SetStoneTip(tooltip, isHealth)
    local srcName = Shards.healthStoneSrc;
    if not isHealth then
        srcName = Shards.soulStoneSrc
    end

    local detail = ""
    if not srcName or srcName == "" then
        srcName = "Unknown"
    else
        detail = GetDetail(srcName)
    end


    --local lineCount = tooltip:NumLines()
    --local title = _G[tooltip:GetName().."TextLeft"..lineCount]
    local r,g,b = GetItemQualityColor(GetQualityFromID(srcName))

    local text = "|cffffffffSoul of |r"..rarityColors["inline"][GetQualityFromID(srcName)]..GetNameFromID(srcName).."|r"
    tooltip:AddLine(text)--, r,g,b)
    if detail and detail ~= "" then
        local det = "["..detail.."]"
        tooltip:AddLine(det)
    end
    tooltip:Show()
    --title:SetText(text)
    --title:SetTextColor(r,g,b) 
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
        local concat = "a"
        if string.find( "aeiouAEIOU",string.sub(name, 1, 1)) then
            concat = "an"
        end
        retText = concat.." "..name
    end
    return retText
end

function GetDetail(uid)
    local name, type, level, rank, realLevel = strsplit("_",uid)
    local refLevel = UnitLevel("player")
    local retText = ""
    if type == "Player" then
        if not realLevel then
            realLevel = refLevel + level
        end
        local table = {}
        FillLocalizedClassList(table)
        local class = table[rank]
        if class then
            retText = realLevel.." "..class
        else
            retText = realLevel.." Player"
        end
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
        Shards.UseEmotes = true;
        Shards.healthStoneSrc = "";
        Shards.soulStoneSrc = "";
        Shards.debug = false
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
            DebugLog("Had recent kill, assuming Shard is from " .. lastShardKill .. " : setting ID at " .. newShardLoc)
            Shards[newShardLoc] = lastShardKill
            lastShardKill = "-1"

        -- Shard moved in bag (one new and one lost), just update its position
        elseif hadShardAt ~= "" then
            DebugLog("Shard Moved from " .. hadShardAt .. " to " .. newShardLoc)
            Shards[newShardLoc] = Shards[hadShardAt]
        --else
        --    DebugLog("Unidentified Shard - Randomizing")
        --    Shards[newShardLoc] =  "Unknown_000_0_normal_-1"
        end
    end

    -- Missing a Shard and we have the info, what did we do with it?
    if hadShardAt ~= "" then
        local shardSrc = Shards[hadShardAt]

        -- Created a Healthstone
        if lastAction == "HStone" then
            DebugLog("Healthstone created from " .. shardSrc)
            Shards.healthStoneSrc = shardSrc
            lastAction = ""

        -- Created a Soulstone
        elseif lastAction == "SStone" then
            DebugLog("Soulstone created from " .. shardSrc)
            Shards.soulStoneSrc = shardSrc
            lastAction = ""

        -- Summoned a Demon
        elseif lastAction == "Demon" then
            local msg = "summoned a " .. demonSummoned .. " using the soul of " .. GetNameFromID(shardSrc).."."
            SendChatMessage(msg, "EMOTE", nil, nil)
            demonSummoned = ""
            lastAction = ""

        -- Summoned a Player
        elseif lastAction == "SummonPlayer" then
            local msg = "summoned " .. summonPlrSrc .. " using the soul of " .. GetNameFromID(shardSrc).."."
            SendChatMessage(msg, "EMOTE", nil, nil)
            Shard_COM_SendSource(SMAction, shardSrc, UnitName("target"))
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
        DebugLog("Found a new shard in our bag: " .. locationID)
        newShardLoc = locationID
    elseif Shards[locationID] and not isShard then
        -- We used to have a shard here, now it's missing!
        DebugLog("We're missing a shard! - Checking where it went")
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
        return COMMON
    end

    local level, rank, type = 0
    local uid = Shards[location]
    local name, type, level, rank = strsplit("_",uid)
    if type == "Creature" then
        if level == -100 or rank == "worldboss" then
            return LEGENDARY
        elseif tonumber(level) >= -3 then
            if rank == "elite" or rank == "rareelite" then
                return UNCOMMON
            else
                return COMMON
            end
        else
            return POOR
        end
    elseif type == "Player" then
        if level == -100 then
            return ARTIFACT
        elseif tonumber(level) >= 0 then
            return EPIC
        else
            return RARE
        end
    else
        return COMMON
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
    if Shard_IsValidName(UnitName) then
        C_ChatInfo.SendAddonMessage(Shard_Channel, action..":"..Src, "WHISPER", UnitName)
    end
end

function GotMessage(msg, sender)
    DebugLog("Got ShardMsg " .. msg)
    itype, unit = strsplit(":", msg)
    if itype and itype == HSAction then
        Shards.healthStoneSrc = unit
        DebugLog("Healthstone Source: " .. Shards.healthStoneSrc)
    elseif itype and itype == SMAction then
        print("|cFFff8080You have been summoned using the soul of " .. GetNameFromID(unit)..".|r")
    elseif itype and itype == SSAction then
        Shards.soulStoneSrc = unit
    end
end

function Shard_IsValidName(UnitName)
    return UnitName ~= _G["UNKNOWN"] and UnitName ~= _G["UNKNOWNOBJECT"]
end

function CheckForHSTrade(isComplete)
    if isComplete then
        if hasHSInTrade then
            Shard_COM_SendSource(HSAction, Shards.healthStoneSrc, tradeTarget)
            Shards.healthStoneSrc = ""
        end
    else
        hasHSInTrade = false
        for index=1,7 do
            local name = GetTradePlayerItemInfo(index)
            if name and string.find(name, "Healthstone") then
                hasHSInTrade = true
                return
            end
        end
    end
end

hooksecurefunc("ContainerFrameItemButton_OnEnter", function(self)
    SetCursorPos(self)
end)

-- Set Tooltip for Soulstone
hooksecurefunc(GameTooltip, "SetUnitAura", function(self, unit, index, filter)
	local spellName,_,_,_,_,_,caster = UnitAura(unit, index, filter)
    if string.find(spellName, "Soulstone") then
        local casterName = caster and UnitName(caster)

        srcName = Shards.soulStoneSrc
        if not srcName or srcName == "" then
            srcName = "Molten Giant_0_elite_60"
        end

        local text = "|cffffffffProtected by the soul of |r|cff"..rarityColors["inline"][GetQualityFromID(srcName)+1]..GetNameFromID(srcName).."|r"

        local lineCount = self:NumLines()
        local description = _G[self:GetName().."TextLeft"..lineCount-1]
        description:SetText(text)
        self:Show()
    end
end)

hooksecurefunc(GameTooltip,"SetInventoryItem",function(self,bag,slot)
  SetTooltip(self)
end)

hooksecurefunc(GameTooltip,"SetBagItem",function(self,bag,slot)
  SetTooltip(self)
end)

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

-- Update Method to check if mouse is over any of the Bank Frame slots
-- It seems like there should be a better way to do this...
function ShardSource_OnUpdate()
    CheckBagOpenChanged()
    if bankOpen == 1 then
        CheckBankHover()
    end
end

function DebugLog(toPrint)
    if Shards.debug then
        print(toPrint)
    end
end

-- Function Hooks
--GameTooltip:HookScript("OnTooltipSetItem", SetTooltip)
ItemRefTooltip:HookScript("OnTooltipSetItem", SetTooltip)
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("TRADE_SHOW")
f:RegisterEvent("TRADE_ACCEPT_UPDATE")
f:RegisterEvent("TRADE_CLOSED")
f:RegisterEvent("TRADE_REQUEST_CANCEL")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("BANKFRAME_OPENED")
f:RegisterEvent("BANKFRAME_CLOSED")
f:RegisterEvent("CHAT_MSG_ADDON")
print("Loaded |cFF"..rarityColors.inline[EPIC].."[ShardSource]|r by Blueteak.")
