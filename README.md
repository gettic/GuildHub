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

Type `/ghub` or click the Guild Hub minimap button to open it. It lists every online guildmate with rank, level, zone, what they are doing and for how long (for example "for 12 min"). Hover a row to see how long the status has lasted and when it clears, such as "for 45 min · clears in 15 min". Each row has Whisper and Invite buttons. Left-click the Sort button to go to the next sort (activity, level, zone, rank, name) and right-click to go back. Search by name, zone, status or rank; press Esc in the search box to clear it. Guildmates without Guild Hub show greyed out.

**Your status.** Pick LFG (then choose a dungeon), Need help, Farming, Leveling, Busy or Open to chat. You can add a short note of up to 60 letters. A new status lasts 1 hour. The "Lasts" button changes that to 1, 2, 4 or 8 hours: left-click for longer, right-click for shorter. Changing the note or the dungeon keeps the time. Choosing another status, or turning it off, clears the old note. Nothing is shared until you press Enter in the note box. "Press Enter to share" shows while your typed note is not shared yet. In the dungeon list, right-click closes it.

**Automatic activity.** Guild Hub also shares what you are doing (in a dungeon, gathering, AFK, in town, at an inn...). To share only the status you pick yourself, turn off "Share my activity automatically" in the settings.

**Notes.** A small note, with no sound, appears when a guildmate within 5 levels of you starts LFG, or when someone asks for help. You get at most one per player every 5 minutes. Use "Mute" on a note to stop a player's notes (this also hides their status text). Unmute them, or switch the notes off, in the settings.

**Minimap button.** Left-click opens the window. Right-click opens the settings. Drag to move it. Hover it to see how many guildmates are looking for a group or need help. You can hide it in the settings.

If the game blocks the Invite button, Guild Hub puts `/invite Name` in your chat box. Press Enter to send it.

## Install

Copy the `GuildHub` folder into your WoW `AddOns` folder, then restart the game or reload the UI. Everyone in the guild needs the addon to see each other.

## Commands

| Command | What it does |
|---|---|
| `/ghub` | Open or close the status board |
| `/ghub help` | Show the list of commands |
| `/ghub status` | Show who has Guild Hub and which version |
| `/ghub options` | Open the settings |
| `/ghub debug` | Show addon messages |
| `/ghub test big` | Run a test of splitting a long message |
| `/ghub test activity` | Show what Guild Hub thinks you are doing |
| `/ghub test expire` | Make your status run out |

## Settings

Open them with `/ghub options`, the minimap button's right-click, or Options > AddOns > Guild Hub. There you can switch off automatic activity and the notes, unmute players, show or hide guildmates without Guild Hub, and hide the minimap button. The Guild Master sets which ranks count as officers.

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
| `UI\MainFrame.lua` | The window and the minimap button |
| `UI\StatusTab.lua` | The status board tab |
| `Options.lua` | Settings page |

## Credits

Uses the embedded libraries Ace3 (BSD-style licence, see `GuildHub\Libs\Ace3-LICENSE.txt`) and HereBeDragons (not used until the map is built). They keep their own licences. Guild Hub itself is all rights reserved: you may download it and use it to play, but not copy, change or redistribute it (see `LICENSE`).
