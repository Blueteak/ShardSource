# ShardSource
Shard Source is an addon for tracking the source of Warlock Soul Shards. No longer will souls be unceremoniously stuffed into a the corner of a bag or the nth slot of your soul pouch. Instead, each soul will be tracked as you drain them, leaving you with a visual history of your conquests and trophies to fill up your extra bank slots!

**Forever beta issue, September 19, 2026:** The client can write addon saved data but fail to load it on reload or login. This also affects recovered soul names. `/ssrc status` reports how many records were loaded so this can be distinguished from a name restriction. See the [beta bug report](https://us.forums.blizzard.com/en/wow/t/uiaddon-settings-wiped-on-client-restart/2353992).

## Features

### Soul Shard Names

Readable mob names are saved directly. For any unreadable name, starting a Drain Soul channel triggers one self-whisper containing `%t`, before the target can die or be cleared. All shards from that channel share a pending record, which follows the soul into stones, demons, and returned shards. A readable reply from your own player GUID saves the name. Request tokens keep replies matched to the right capture. Restricted replies with readable chat-line IDs are retried for up to sixty seconds. If the target changed between capture and the name request, the whisper is skipped. Failed or unresolved whispers leave Unknown Soul. `/ssrc status` shows the latest result.
![](https://i.imgur.com/gRUvWG4.png)

Each soul shard you collect will retain information about what enemy it came from, color-coded to how powerful the enemy was. Ordinary creatures four or more levels below you are poor quality souls. Elite and rare-elite souls stay green when below your level, same-level player souls are epic, and boss souls are legendary!

Restricted names and creature GUIDs are no longer retained for tooltip display or later lookup. Pending whispers do not survive reloads; successfully saved names do, subject to the beta loading issue above.

### Consumable Source

ShardSource filters its marked self-whispers from the normal chat display, including incoming and outgoing copies. Ordinary whispers remain visible. Explicit probes and enabled debug logging still print diagnostics. If the client prevents filtering a restricted message, that message may remain visible.
![](https://i.imgur.com/IMWxMqF.png)

Crafted Healthstones and Soulstones will keep a reference to what Soul was used to create them. Additionally summoning demons or other players will emote publicly what soul was used to summon them.

Your summoned demon's mouseover tooltip replaces the owner line with `<Summoned from Hogger's soul>`, using the consumed soul's name and quality color. This is visible only to you and starts with your next tracked summon. Readable sources are saved for reuse with the same demon after a UI reload, subject to the beta loading issue above. Imps do not consume a shard and keep their normal tooltip.

If a tracked demon despawns and returns a Soul Shard, that shard keeps the demon's original soul name and quality. The addon matches a single new, unidentified shard arriving around the disappearance; ambiguous returns stay unknown.

### Cross-Player Data
![](https://i.imgur.com/gwkndM1.png)
Even if you're not a warlock, you can still get value out of this addon! Healthstones that are traded to you and Soulstone Resurrection will show what soul the warlock used to create those items.

## Slash Commands
Commands start with `/ssrc` or `/shardsrc` interchangably.

```/ssrc emote```
Toggles the public emoting part of the addon for summoning players/demons and using a soulstone on a player.

```/ssrc debug```
Toggles logging of shard-based actions, useful for debugging

```/ssrc status```
Shows shard name counts, loaded/current saved records, pending self-whispers, and the latest shard match and whisper result.

```/ssrc retry```
Rechecks retained whisper replies in chat history. It does not send another whisper or look up creature identities.

```/ssrc probe```
Checks whether the current target's name, GUID, and a fresh name lookup by GUID are readable, secret, or missing. Also checks `UnitCreatureID` and the target tooltip's GUID, title, and name lookup, reporting unavailable APIs or lookup errors separately. When out of combat and addon chat is allowed, it sends one `SSRC:%t` whisper to yourself and arms the chat probe to test target-name expansion through the addon API. It does not change shard records. Target a living dungeon enemy before anyone pulls and run this command. Compare with an outdoor enemy.

For an experimental chat-history name lookup, use `/ssrc chatprobe arm`, then manually whisper yourself `SSRC:%t` while targeting the dungeon enemy. The probe captures the next incoming whisper within 60 seconds, which may be another player's if they message first. It reports message/line-ID readability and queries the chat text immediately. Leave the dungeon without reloading and run `/ssrc chatprobe` to repeat the lookup. Readable text is printed so you can check whether the target name expanded. The probe sends no messages and changes no shard records. `/ssrc chatprobe cancel` clears it; reload also clears it.

## Publishing

CurseForge packages this repository using `.pkgmeta` and Git version tags. See [RELEASING.md](RELEASING.md) for setup and publishing instructions.
