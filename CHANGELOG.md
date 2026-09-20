# Unreleased

- Shows the soul used to summon your current demon in its mouseover tooltip, replacing the owner line.
- Remembers the source across UI reloads for the same summoned demon.
- Restores the original soul name and quality to a shard returned when a tracked demon despawns.
- Captures Drain Soul sources earlier, preserves readable names when quality details are unavailable, and reports restricted spell events in `/ssrc status`.
- Keeps restricted soul names in session memory for tooltip display, including crafted stones, summoned demons, and refunded shards.
- Retries names using the original creature identity after combat, bag updates, restriction changes, and zone changes; saves names only when a fresh lookup is readable. Adds `/ssrc retry` and recovery diagnostics.
- Keeps elite and rare-elite souls green even when the enemy is below your level.
- Makes a final name recovery attempt at logout or UI reload and shows its saved result in `/ssrc status` after login.
- Restores missing saved shard entries from readable session records. Recovery reports now distinguish name lookups from saved-record updates, and `/ssrc status` includes loaded and saved record counts plus the tracker revision.

Known Forever beta issue, September 19, 2026: the client can write SavedVariables files but fail to load them after a reload or login. Recovered soul names can therefore return to Unknown despite a successful lookup. This affects other addons as well; see the [beta bug report](https://us.forums.blizzard.com/en/wow/t/uiaddon-settings-wiped-on-client-restart/2353992). The addon reports loaded and saved record counts to help identify this client issue.

# 2.0.0

Adds support for WoW Forever 1.60.1, interface 16001.

- Replaces the old bag and tooltip APIs with the current Forever APIs.
- Records readable Drain Soul sources and displays their names on Soul Shards.
- Keeps shard names attached to individual items when moved or sorted.
- Records the consumed soul for Healthstones and Soulstones.
- Supports separate bags, combined bags, and the Forever bank layout.
- Respects secret values and chat restrictions. Unavailable sources appear as Unknown Soul.
- Adds `/ssrc status` for client version, shard counts, and tracking information.

Reloading, new shard names, and Healthstone source tooltips have been checked in the live beta client. Bank visuals and player-to-player trades still need live testing.
