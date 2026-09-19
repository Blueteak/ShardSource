# Unreleased

- Shows the soul used to summon your current demon in its mouseover tooltip, replacing the owner line.
- Remembers the source across UI reloads for the same summoned demon.

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
