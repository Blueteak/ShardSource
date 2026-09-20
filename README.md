# ShardSource
Shard Source is an addon for tracking the source of Warlock Soul Shards. No longer will souls be unceremoniously stuffed into a the corner of a bag or the nth slot of your soul pouch. Instead, each soul will be tracked as you drain them, leaving you with a visual history of your conquests and trophies to fill up your extra bank slots!

**Forever beta issue, September 19, 2026:** The client can write addon saved data but fail to load it on reload or login. This also affects recovered soul names. `/ssrc status` reports how many records were loaded so this can be distinguished from a name restriction. See the [beta bug report](https://us.forums.blizzard.com/en/wow/t/uiaddon-settings-wiped-on-client-restart/2353992).

## Features

### Soul Shard Names
![](https://i.imgur.com/gRUvWG4.png)

Each soul shard you collect will retain information about what enemy it came from, color-coded to how powerful the enemy was. Ordinary creatures four or more levels below you are poor quality souls. Elite and rare-elite souls stay green when below your level, same-level player souls are epic, and boss souls are legendary!

When WoW restricts a creature's name, the addon keeps it temporarily for tooltip display and retries a lookup for that same creature after bag updates, combat, restriction changes, and zone changes. A readable result becomes a saved name. Temporary names follow the soul into your demon, returned shard, Healthstone, or Soulstone, but cannot be shared through chat and are lost on reload/logout unless recovered first. Recovered names still depend on the client loading saved data correctly. This recovery is experimental on the Forever beta; the game may continue restricting the name or stop knowing the creature.

### Consumable Source
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
Shows saved and session-only shard name counts, capture details, and the last delayed lookup and temporary tooltip results. The addon also retries immediately before logout or UI reload; this command shows that attempt's saved result afterward.

For persistence troubleshooting, it also shows the tracker revision, shard records loaded from disk, current saved records, and counts from the last logout or reload. Recovery reports count updated shard records separately from successful name lookups.

```/ssrc retry```
Retries unresolved names using their original creature identities and reports the result. Useful after leaving a dungeon, before reloading.

## Publishing

CurseForge packages this repository using `.pkgmeta` and Git version tags. See [RELEASING.md](RELEASING.md) for setup and publishing instructions.
