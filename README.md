# Guild Hub

A guild hub for WoW Forever that lets guildmates see what everyone is doing, where they are on the map and what they can craft.

## What it does now

- Shares basic info (addon version, level, class) with guildmates who also have Guild Hub.
- Syncs saved data with them when you log in.
- A status board: a window that shows what every online guildmate is doing.
- Your own status: pick one, add a short note, and your guild sees it.
- Small alerts when a guildmate near your level looks for a group, or someone asks for help.

Planned next: professions and a guild map. They are not built yet.

## Status board

Type `/ghub` or click the Guild Hub minimap button to open it. It lists every online guildmate with rank, level, zone, what they are doing. How long they have had that status shows in grey at the right end of the STATUS column (for example "12 min"). Hover a row to see when it clears, such as "for 45 min · clears in 15 min". Each row has Whisper and Invite buttons. Click the Sort menu to sort by activity, level, zone, rank or name. Tick "LFG only" to list only guildmates looking for a group. Search by name, zone, status or rank; press Esc in the search box to clear it. Guildmates without Guild Hub show greyed out. The window uses Blizzard's own look, with the Status and Settings tabs at the top, just under the title.

**Your status.** Pick LFG (then choose a dungeon), Need help, Farming, Leveling, Busy or Open to chat. You can add a short note of up to 60 letters. A new status lasts 1 hour. The "Lasts" button changes that to 1, 2, 4 or 8 hours: left-click for longer, right-click for shorter. Changing the note or the dungeon keeps the time. Choosing another status, or turning it off, clears the old note. Nothing is shared until you press Enter in the note box. "Press Enter to share" shows while your typed note is not shared yet. The dungeon is picked from a drop-down menu.

**Group column.** GROUP shows who is in a group. Green "Yours" means they are in your group (works for everyone, also without Guild Hub). "3/5" is a party of 3, "R 18" a raid of 18, "-" is no group. Empty means they have an older Guild Hub. Invite is greyed out for players already in your group. Only the number is shared, never names. To share nothing about your group, turn off "Share my group size" in the settings.

**Automatic activity.** Guild Hub also shares what you are doing (in a dungeon, gathering, AFK, in town, at an inn...). In a dungeon or raid, it shows which one by its short name, such as "In a dungeon: RFC" or "In a raid: MC" (the tooltip has the full name). A status you picked yourself still shows instead. To share only the status you pick yourself, turn off "Share my activity automatically" in the settings.

**Notes.** A small note, with no sound, appears when a guildmate within 5 levels of you starts LFG, or when someone asks for help. You get at most one per player every 5 minutes. Use "Mute" on a note to stop a player's notes (this also hides their status text). Unmute them, or switch the notes off, in the settings.

**Mini mode.** Click the "-" button next to the close button to switch to a small window you can move. It only lists guildmates with Guild Hub and what they are doing. Click a name to whisper. Click "+" to go back to the full window. `/ghub` and the minimap button always open the full window (if the mini window is showing, it closes). Esc does not close the mini window: use its x.

**Minimap button.** Left-click opens the window. Right-click opens the Settings tab. Drag to move it. Hover it to see how many guildmates are looking for a group or need help. You can hide it in the settings.

If the game blocks the Invite button, Guild Hub puts `/invite Name` in your chat box. Press Enter to send it.

## Install

Copy the `GuildHub` folder into your WoW `AddOns` folder, then restart the game or reload the UI. Everyone in the guild needs the addon to see each other.

## Commands

| Command | What it does |
|---|---|
| `/ghub` | Open or close the status board |
| `/ghub help` | Show the list of commands |
| `/ghub status` | Show who has Guild Hub and which version |
| `/ghub options` | Open the Settings tab |
| `/ghub debug` | Show addon messages |
| `/ghub test big` | Run a test of splitting a long message |
| `/ghub test activity` | Show what Guild Hub thinks you are doing |
| `/ghub test expire` | Make your status run out |

## Settings

Open the Settings tab (top right of the `/ghub` window) with `/ghub options` or the minimap button's right-click. The same settings are in Esc > Options > AddOns > Guild Hub. There you can switch off automatic activity, sharing your group size and the notes, unmute players, show or hide guildmates without Guild Hub, and hide the minimap button. The Guild Master sets which ranks count as officers.

## Good to know

- Trial and Veteran trial accounts can receive data but not send it.
- Data of members not seen for 90 days is deleted.
- Works with WoW Forever character names such as "Mira Ashford".

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
| `Status.lua` | Status logic: presets, activity, alerts, board rows |
| `UI\Widgets.lua` | Buttons, text boxes and the alert note |
| `UI\MainFrame.lua` | The window, its tabs and the minimap button |
| `UI\StatusTab.lua` | The status board tab |
| `UI\MiniFrame.lua` | The small mini mode window |
| `Options.lua` | Settings (the Settings tab and the Options page) |

## Credits

Uses the embedded libraries Ace3 (BSD-style licence, see `GuildHub\Libs\Ace3-LICENSE.txt`) and HereBeDragons (not used until the map is built). They keep their own licences. Guild Hub itself is all rights reserved: you may download it and use it to play, but not copy, change or redistribute it (see `LICENSE`).
