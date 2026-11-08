# Guild Hub

A guild hub for WoW Forever that lets guildmates see what everyone is doing, where they are on the map and what they can craft.

## What it does now

- Shares basic info (addon version, level, class) with guildmates who also have Guild Hub.
- Syncs saved data with them when you log in.

Planned next: a status board, professions and a guild map. They are not built yet.

## Install

Copy the `GuildHub` folder into your WoW `AddOns` folder, then restart the game or reload the UI. Everyone in the guild needs the addon to see each other.

## Commands

| Command | What it does |
|---|---|
| `/ghub` | Show help |
| `/ghub status` | Show who has Guild Hub and which version |
| `/ghub debug` | Show addon messages |
| `/ghub test big` | Run a test of splitting a long message |
| `/ghub options` | Open the settings |

## Settings

Open them with `/ghub options` or in Options > AddOns > Guild Hub. The Guild Master sets which ranks count as officers.

## Good to know

- Trial and Veteran trial accounts can receive data but not send it.
- Data of members not seen for 90 days is deleted.

## For people who change the code

The addon lives in `GuildHub\`. Files are loaded in this order (see `GuildHub_Forever.toc`):

| File | Job |
|---|---|
| `Locale.lua` | Text |
| `Util.lua` | Small helpers |
| `Core.lua` | Start-up, timers and the `/ghub` command |
| `Store.lua` | Saved data, merging and 90-day pruning |
| `Roster.lua` | Guild roster |
| `Comm.lua` | Sending and receiving addon messages |
| `Sync.lua` | Syncing data between guildmates |
| `Options.lua` | Settings page |

## Credits

Uses the embedded libraries Ace3 (BSD-style licence, see `GuildHub\Libs\Ace3-LICENSE.txt`) and HereBeDragons (not used until the map is built).
