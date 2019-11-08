local Shard_Channel = "ShardSrc_Channel"
Shard_COMMAND_Send   = "S"

function Shard_COM_Init()
    C_ChatInfo.RegisterAddonMessagePrefix(Shard_Channel)
    C_ChatInfo.IsAddonMessagePrefixRegistered(Shard_Channel)
end

function Shard_COM_SendSource(UnitName, Src)
    print("Attempting Src Send to "..UnitName.." of: "..Src)
    if IAAM_CORE_IsValidName(UnitName) then
        C_ChatInfo.SendAddonMessage(Shard_Channel, Shard_COMMAND_Send..":"..Src, "WHISPER", UnitName)
    end
end
