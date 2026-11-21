# Guild Hub

A guild hub for WoW Forever that lets guildmates see what everyone is doing, where they are on the map and what they can craft.

## Getting started

After you install Guild Hub, a short "Getting started" walkthrough opens once on each character, but only while something needed is still to do. It comes right after the map question, or at your next login if you answered that with "Not now". It never shows in combat or in a dungeon. Use Back and Next to move between its pages. Tick "Don't show this by itself again" to stop it on all your characters. Open it again any time with `/ghub start` or the "Getting started" button in Settings.

| Page | What it shows |
|---|---|
| 1. Start | What is needed so Guild Hub works for you, and the optional extras |
| 2. Share your professions (needed) | A Turn on button, then one row per profession |
| 3. Map position and group size (needed) | A Turn on button for each |
| 4. The status board (optional) | What the board does, and an Open board button |
| 5. Recruiting (optional) | What the Recruiting tab does, and an Open tab button |

Each mark comes from your real settings, so it ticks itself off as you go. "Turn on" changes only that one setting. The walkthrough itself sends nothing.

**Professions.** Each profession row says "Read: N recipes", or that you still need to open its window once from your spellbook. Guild Hub can only read your recipes while the window is open (Cooking and First Aid too). After that, new recipes are added by themselves. Herbalism, Skinning and Fishing have nothing to open.

**Map position and group size.** You only see from others what you share yourself (see [Fair trade](#fair-trade)). Your position is sent only out in the world and never saved. Your group size is only a number, never names. Turn either off any time in Settings > What I share.

The Recruiting page only shows when the Guild Recruiter is on. On Trial and Veteran accounts the walkthrough is one page: sharing is locked, and the status board works.

## What it does now

- Shares basic info (addon version, level, class) with guildmates who also have Guild Hub.
- Syncs saved data with them when you log in.
- A status board: a window that shows what every online guildmate is doing.
- Your own status: pick one, add a short note, and your guild sees it.
- Small alerts when a guildmate near your level looks for a group, or someone asks for help.
- A Professions tab: who has which profession, and who can make an item.
- A "crafted by" line in item tooltips.
- Guild map dots: guildmates who share their position show on the world map and the minimap, with a hover card, dungeon labels and a "Find me" button.
- A short Getting started walkthrough.
- A Guild Recruiter (beta): a Recruiting tab with what the guild needs, the guild makeup, the guild's ad to post or copy, and lists for officers.

Planned next: a Map tab in the window. It is not built yet.

## Status board

Type `/ghub` or click the Guild Hub minimap button to open it. It lists every online guildmate with rank, level, zone, what they are doing. How long they have had that status shows in grey at the right end of the STATUS column (for example "12 min"). Hover a row to see when it clears, such as "for 45 min · clears in 15 min". Each row has Whisper and Invite buttons. Click the Sort menu to sort by activity, level, zone, rank or name. Tick "LFG only" to list only guildmates looking for a group. Search by name, zone, status or rank; press Esc in the search box to clear it. Guildmates without Guild Hub show greyed out. The window uses Blizzard's own look. The Status tab sits on the top edge of the list, with Search, Sort and "LFG only" beside it. Settings is the gear button in the title bar.

**Your status.** Pick LFG (then choose a dungeon), Need help, Farming, Leveling, Busy or Open to chat. You can add a short note of up to 60 letters. A new status lasts 1 hour. The "Lasts" button changes that to 1, 2, 4 or 8 hours: left-click for longer, right-click for shorter. Changing the note or the dungeon keeps the time. Choosing another status, or turning it off, clears the old note. Nothing is shared until you press Enter in the note box. "Press Enter to share" shows while your typed note is not shared yet. The dungeon is picked from a drop-down menu.

**Group column.** GROUP shows who is in a group. Green "Yours" means they are in your group (works for everyone, also without Guild Hub). "3/5" is a party of 3, "R 18" a raid of 18, "-" is no group. Empty means they have an older Guild Hub. Invite is greyed out for players already in your group. Only the number is shared, never names. To share nothing about your group, turn off "Share my group size" in the settings.

**Automatic activity.** Guild Hub also shares what you are doing (in a dungeon, gathering, AFK, in town, at an inn...). In a dungeon or raid, it shows which one by its short name, such as "In a dungeon: RFC" or "In a raid: MC" (the tooltip has the full name). A status you picked yourself still shows instead. To share only the status you pick yourself, turn off "Share my activity automatically" in the settings.

**Notes.** A small note, with no sound, appears when a guildmate within 5 levels of you starts LFG, or when someone asks for help. You get at most one per player every 5 minutes. Use "Mute" on a note to stop a player's notes (this also hides their status text). Unmute them, or switch the notes off, in the settings.

**Mini mode.** Click the "-" button next to the close button to switch to a small window you can move. It only lists guildmates with Guild Hub and what they are doing. Click a name to whisper. Click "+" to go back to the full window. `/ghub` and the minimap button always open the full window (if the mini window is showing, it closes). Esc does not close the mini window: use its x.

**Minimap button.** Left-click opens the window. Right-click opens Settings. Drag to move it. Hover it to see how many guildmates are looking for a group or need help. You can hide it in the settings.

If the game blocks the Invite button, Guild Hub puts `/invite Name` in your chat box. Press Enter to send it.

## Professions

Click the Professions tab to see which guildmates have which profession and how high their skill is. Use the recipe search to ask "who can make X?". The Request button writes a polite whisper into your chat box. You press Enter yourself: Guild Hub never sends it for you. A quiet feed shows rare recipes that guildmates learned.

Open each of your profession windows once, so Guild Hub can read your recipes.

**Your own characters.** Guild Hub remembers every character you log in with on this account. This stays on your PC and is never sent to anyone. In the recipe search, the request popup and the "crafted by" tooltip, they show in gold as "You" or "You (alt): Name". They have no Whisper or Request button ("log in to craft") and are listed after your guildmates. The status board never offers Whisper or Invite for them. Each alt is recognised after it has logged in once with this version. A character is forgotten when you haven't played it for a year, or at once if it shows up online while you are logged in (then it isn't yours).

**Tooltips.** Item tooltips get one extra line, "Guild Hub: crafted by ...", when a guildmate can make the item. It never shows in combat. You can turn it off in the settings.

**Privacy.** "Share my professions" in the settings is on by default. Turning it off tells the guild to forget your professions. Guild Hub only fetches recipe lists after you first use the Professions tab, the search or a tooltip, and sends them slowly to keep the chat channel free. Professions of players who leave the guild are deleted.

## Guild map

Guildmates who share their position show as class-coloured dots on the world map and the minimap. Dots of guildmates who are AFK are dimmed. Players on your ignore list get no dot. The world map also shows how many guildmates are in each zone (from the guild list).

**Hover card.** Hover a dot to see a card with the name, level, class, rank, zone, status, group size, professions and how long ago the position was sent. If other dots sit right next to it, an "Also here" line names them. Group size and professions show only if you share those yourself (see [Fair trade](#fair-trade)). No card in combat.

**Dungeon labels.** On the world map, dungeon entrances show how many online guildmates are inside, for example "The Deadmines 2". Blackrock Mountain has one combined label, such as "Blackrock Mountain: BRD 2 · MC 5". Only numbers show, never names. The counts come from the guild list and from statuses, and nothing is sent for them.

**Find me.** Lost your guildmates, or want them to spot you? Click the "Find me" button on the Status tab, or type `/ghub findme`. Your dot pulses on the maps of guildmates who share their position, and they get one chat line. It works only while you share your exact position, and at most once every 30 seconds. Turn the chat line off with "Show Find me lines in chat" in Settings > Guild map. Muting someone stops their pulses and lines.

**Sharing your position.** The first time on each character, a small "Guild Hub" card asks: "Share my position", "Zone only" or "Not now". "Zone only" is a lasting no: guildmates see only your zone in the guild list, and the card stops asking. "Not now" asks again next login. Turning it off in Settings > What I share is also a real no. Your position is:

- sent only in the open world, never in dungeons, raids or battlegrounds
- sent at most every 12 seconds, and only when you move
- sent only to your guild, and never saved
- hidden while you are AFK (your dot goes, and comes back when you return)

The Guild map section in Settings has these switches: the minimap dots, "Hide my dot while AFK" (on by default) and "Show Find me lines in chat" (on by default). `/ghub test map` shows three made-up guildmates for 60 seconds, only on your screen.

## Guild Recruiter

This part is in beta. Open the Recruiting tab in the `/ghub` window. The list on the left has Overview and New members for everyone. Officers also see Ad builder, Officer lists and Suggestions & trials.

**Overview.** Everyone sees:

- **We need:** how many tanks, healers and damage the guild wants, and which classes are wanted or closed.
- **Guild makeup:** per class, how many members are level 60 and level 50+ (from the guild list).
- **The guild's ad:** a short recruitment text, written by the officers.
- **Guild totals:** how many joined in the last 30 days, how many of them are still here, and the average number online. This needs "Keep guild history on this computer" (see [Settings](#settings)). Officers also see who left and came back.

**What officers set.** Officers set the needs (they last 14 days), the ad and a Discord invite, then press "Save for the guild". "Unsaved changes" shows until they do. The ad has at most 200 letters (accented letters count as one letter each), and it must fit in one chat line. Links, web addresses and words like Blizzard, GM, Official, gold or boost are not allowed. The Discord invite (discord.gg/... or discord.com/invite/...) only shows in the Copy box. Officers also tick "Members may post in General/Trade".

**Posting the ad.** Under "Where the ad goes", "Post in General" and "Post in Trade" post the ad as you: one line per click. A line under them says "Ready", "Post again in N min" or "Posting is off (officers)". A preview shows how the ad reads in chat. Posting has firm limits:

- off until an officer turns it on
- 1 post per player per hour (a failed try counts too)
- 2 posts per hour for the whole guild
- 20 minutes between posts in the same channel (for General: in the same zone)
- never in combat, dungeons, raids or battlegrounds

The first press only shows a short note: "Posts as you. Follow channel rules; spamming can be reported." The next press posts.

For about 20 seconds after login (or after leaving a dungeon) you see "checking when guildmates last posted" while Guild Hub learns when the guild last posted. Try again after that. If the game is slow to show your post, you see "couldn't see your post in the channel yet". It still counts for the limits.

**Post button (optional).** "Make post button" makes a character macro, "GH Recruit", that runs `/ghub ad general` or `/ghub ad trade` (General by default). Drag it to your bar and press it to post. It has the same limits. It is hidden while posting is off.

**Ad builder** (officers only). Pick the raid size, raid days, start time, time zone, loot, style and level from fixed lists. Guild Hub builds the one-line ad from them. If it is too long for one chat line, it leaves out the style, then the raid size, then the classes. "Use this" puts the ad in the Overview text box (your text there is replaced; Revert brings back the saved one). "Save for the guild" shares the fields. Nothing is posted by itself. Under the ad text on the Overview page, officers see a hint when the ad has no raid days, start time or loot.

**Discord and forums.** Copy (or `/ghub recruit`) shows the ad and the Discord invite to copy. Below them it also shows a longer post for Discord or a forum: guild, needs, raid days and time, loot, style and the Discord invite. No member names are in it. "Guild Finder" opens the game's own Guild Finder.

**Suggest to officers.** Right-click a player outside the guild and pick "Suggest to officers". You can also pick up to 4 players from your own group under "Suggest from your group" on the Overview page. Only the name and a class/role tag go to one online officer with Guild Hub. You can suggest 3 players a day, and the same player once a week. Not in combat or instances.

**Officer lists** (officers only). Prospects (status new, contacted, trial, no or joined) and Don't invite. Right-click a player outside the guild: the "Guild Hub" group in the menu has Invite to guild, Add to prospects and Don't invite. The lists hold only a name, a status, the date and which officer set it. They are:

- shared in officer chat only, and synced between officers at login
- deleted after 30 days
- removed from a computer whose player is no longer an officer

"Clear list" needs a second click while it counts down.

**Invite to guild** (officers only). One click sends one invite. At most 10 per hour, once per player per 7 days, and never someone on Don't invite. If the game blocks it, `/ginvite Name` is put in your chat box; press Enter to send it.

**Suggestions & trials** (officers only). Members' suggestions can be moved to Prospects or removed. To start a trial, right-click a member and pick Start trial (7, 14 or 30 days). The list shows when each trial ends; "+7 d" adds a week (at most 30 days from today). Once per login you get one chat line when a trial has ended or ends within a day. Trials are a reminder only: Guild Hub never promotes or removes anyone.

**Marking players who want a guild.** The setting "Mark chat lines from players looking for a guild" is off by default. When on, it puts a small [wants a guild] tag in front of channel lines (General, Trade...) that ask for a guild. It saves and sends nothing.

**New members.** When someone joins, a small note shows "Name joined the guild", with who invited them if the game's log says. "Say welcome" puts a welcome line in your guild chat box; you press Enter. Turn the note off in Settings ("Show a note when someone joins the guild"). Officers also get a "Pick a buddy" button on that note. A new member with Guild Hub gets a welcome card once, within two days of joining (this needs "Keep guild history on this computer"); it names their buddy.

**New members page (buddies).** Everyone can tick "I'll be a buddy for new members" (it lasts 90 days; click again to stop). A buddy sees the new guildmates they were asked to help, and when each was last online. Officers see everyone who joined in the last 14 days with when they were last online. Those not online for 4 days or more ("gone quiet") come first. Officers pick a buddy for each with one click. A pairing ends after 14 days. Only the two of them and officers see it. These are reminders only: no scores, and the "gone quiet" list is worked out on your computer and not sent.

## Fair trade

What you don't share, you can't see from others either:

| If you don't share | You lose |
|---|---|
| Your position | The map dots (zone counts stay) |
| Your professions | The Professions tab is locked, with a button to share |
| Your group size | The GROUP column shows "-" |

Trial and Veteran accounts can't share, so these parts are locked for them. The status board stays open to everyone. Settings > What I share lists each item.

## Install

Copy the `GuildHub` folder into your WoW `AddOns` folder, then restart the game or reload the UI. Everyone in the guild needs the addon to see each other.

## Commands

| Command | What it does |
|---|---|
| `/ghub` | Open or close the status board |
| `/ghub help` | Show the list of commands |
| `/ghub status` | Show who has Guild Hub and which version (beta testers too), the guild history counts, and how many addon messages you sent in the last 10 minutes |
| `/ghub options` | Open Settings |
| `/ghub findme` | Make your dot pulse on guildmates' maps (see [Guild map](#guild-map)) |
| `/ghub start` | Open the Getting started walkthrough |
| `/ghub recruit` | Show the guild's recruitment text to copy |
| `/ghub ad trade` / `/ghub ad general` | Post the recruitment text (for the post button; see [Guild Recruiter](#guild-recruiter)) |
| `/ghub selftest` | Check the window and saved data; shows one line to copy and send to the author (no names in it). `/ghub selftest full` also checks the Professions and Recruiting tabs |
| `/ghub debug` | Show addon messages |
| `/ghub test big` | Run a test of splitting a long message |
| `/ghub test activity` | Show what Guild Hub thinks you are doing |
| `/ghub test expire` | Make your status run out |
| `/ghub test ui` | Show which Blizzard art your game gave the window (and a second line to copy) |
| `/ghub test api` | Check which game functions this client has (also chat channels, macros, the last test post, and how many whispers the game hides from addons in combat or instances: the "wsec=" part); shows one line to copy. Changes and sends nothing |
| `/ghub test post` | Check that the ad macro can post: makes a "GH Test Post" macro and shows the steps. It posts only in your own private "ghtest" channel. `/ghub test post remove` deletes the macro |
| `/ghub test map` | Show three made-up guildmates on the map for 60 seconds (only on your screen) |
| `/ghub test prof` | Show what Guild Hub knows about your own professions |

## Settings

Click the gear button in the title bar of the `/ghub` window (left of the "-"), or use `/ghub options` or the minimap button's right-click. Click the gear again to go back to Status. The same settings are in Esc > Options > AddOns > Guild Hub. There you can switch off automatic activity, the "crafted by" tooltip line and the notes, unmute players, show or hide guildmates without Guild Hub, hide the minimap button, and turn the guild dots on the minimap on or off. The "Getting started" button opens the Getting started walkthrough. The Guild Master sets which ranks count as officers.

**What I share.** This is at the top of Settings. It has one line each for your position, your professions and your group size. Each line says "off = you also can't see others'" (see Fair trade). Trial and Veteran accounts can't share, so these lines are locked for them.

**Features.** The Features section lets you switch Professions, the Guild map and the Guild Recruiter on or off for yourself, and turn "Keep guild history on this computer" on or off (on by default). Officers can also switch a part off for the whole guild. They can only switch things off, never on, and the switch stops counting if they lose their officer rank.

**Guild history.** With "Keep guild history on this computer" on, Guild Hub saves these on your computer only. Nothing is sent to anyone:

- when it first saw each guildmate
- how many guildmates are online at each hour (totals only)
- level milestones
- boss kills and failed attempts
- the guild event log (each entry once; copies saved twice by older versions are removed once, keeping the oldest)
- the message of the day, as the game shows it to you

Settings shows what is kept and has a "Clear guild history" button. Later versions will show it as guild firsts, anniversaries and an online heatmap.

## Good to know

- Trial and Veteran trial accounts can receive data but not send it.
- Data of members not seen for 90 days is deleted.
- Works with WoW Forever character names such as "Mira Ashford".
- Guildmates who use Guild Hub show as such within a few seconds after you log in.
- On narrow screens or with a large UI scale, the window shrinks to fit.
- A damaged settings file no longer causes an error: bad settings go back to their defaults and your guild data is kept.
- All addon messages share one budget that stays inside the game's limit, so big guild logins don't get guild messages refused.
- Beta versions are understood. Players on a normal release are only told about newer normal releases.

## For people who change the code

The addon lives in `GuildHub\`. Files are loaded in this order (see `GuildHub_Forever.toc`):

| File | Job |
|---|---|
| `Locale.lua` | Text |
| `Util.lua` | Small helpers |
| `Core.lua` | Start-up, timers and the `/ghub` command |
| `Features.lua` | Switching features on or off (own setting and officer switch) |
| `Events.lua` | Shared game event handling |
| `Budget.lua` | One shared budget for all addon messages |
| `Store.lua` | Saved data, merging and 90-day pruning |
| `Roster.lua` | Guild roster |
| `Alts.lua` | Your own characters on this account (kept only on your PC) |
| `Comm.lua` | Sending and receiving addon messages |
| `Sync.lua` | Syncing data between guildmates |
| `Status.lua` | Status logic: presets, activity, alerts, board rows |
| `Professions.lua` | Professions: reading recipes, sharing them, search, tooltip line |
| `Features\Recorders.lua` | Guild history kept on this computer |
| `Features\Map.lua` | Guild map: sharing and receiving positions |
| `Features\MapDungeons.lua` | Guild map: dungeon entrances and their labels |
| `Features\RecruitOff.lua` | Guild Recruiter: officer lists, the name menu, Invite to guild, trials |
| `Features\RecruitTools.lua` | Guild Recruiter: Suggest to officers, marking chat lines, guild totals |
| `Features\RecruitAds.lua` | Guild Recruiter: the ad builder and the long post |
| `Features\RecruitBuddy.lua` | Guild Recruiter: buddies and "gone quiet" |
| `Features\Recruit.lua` | Guild Recruiter: needs, ad, posting and limits, post button, join notes |
| `UI\Widgets.lua` | Buttons, text boxes and the alert note |
| `UI\MainFrame.lua` | The window, its tabs, the gear button and the minimap button |
| `UI\StatusTab.lua` | The status board tab |
| `UI\ProfessionsTab.lua` | The Professions tab |
| `UI\MiniFrame.lua` | The small mini mode window |
| `UI\Card.lua` | The small card ("Share my position", Getting started) |
| `UI\Guide.lua` | The Getting started walkthrough |
| `UI\RecruitPage.lua` | The Recruiting tab's Overview page, the Copy box and the join note |
| `UI\RecruitAdPage.lua` | The Recruiting tab's Ad builder page |
| `UI\RecruitBuddyPage.lua` | The Recruiting tab's New members page |
| `UI\RecruitOffPage.lua` | The Recruiting tab's officer pages |
| `UI\MapPins.lua` | Dots on the world map and minimap |
| `Options.lua` | Settings (the Settings page in the window and the Options page) |
| `ApiTest.lua` | The `/ghub test api` check |
| `SelfTest.lua` | The `/ghub selftest` check |

## Credits

Uses the embedded libraries Ace3 (BSD-style licence, see `GuildHub\Libs\Ace3-LICENSE.txt`) and HereBeDragons by Nevcairiel (BSD 3-Clause licence, see `GuildHub\Libs\HereBeDragons\LICENSE.txt`; used for the guild map dots). They keep their own licences. Guild Hub itself is all rights reserved: you may download it and use it to play, but not copy, change or redistribute it (see `LICENSE`).
