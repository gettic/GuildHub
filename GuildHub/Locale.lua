-- Guild Hub: all text the player can see, in one place (English only for now).
local _, ns = ...

local L = {}
ns.L = L

L.PREFIX            = "|cff33ccffGuild Hub:|r "
L.DEBUG_PREFIX      = "|cff33ccffGuild Hub:|r |cff888888[debug]|r "

-- /ghub help
L.HELP_HEADER       = "commands:"
L.HELP_OPEN         = "  /ghub - open or close the Guild Hub window (the small one in mini mode)"
L.HELP_STATUS       = "  /ghub status - who has Guild Hub and which version"
L.HELP_DEBUG        = "  /ghub debug - show addon messages as they are sent and received (on/off)"
L.HELP_TEST         = "  /ghub test big - send one long test message to check splitting"
L.HELP_TEST2        = "  /ghub test activity - show what Guild Hub thinks you are doing; /ghub test expire - make your status run out"
L.HELP_OPTIONS      = "  /ghub options - open the Settings tab"

-- /ghub status
L.STATUS_HEADER     = "%d guild members online, %d of them with Guild Hub. Known Guild Hub users:"
L.STATUS_LINE       = "  %s  v%s  level %s  - %s"
L.STATUS_ONLINE     = "|cff40ff40online|r"
L.STATUS_LASTSEEN   = "last seen %s ago"
L.STATUS_NONE       = "  (nobody else yet - ask a guildmate to install Guild Hub)"
L.STATUS_MORE       = "  ... and %d more"
L.NOT_IN_GUILD      = "you are not in a guild, so there is nothing to share."
L.ROSTER_WAIT       = "still loading the guild list, try again in a few seconds."

-- Debug and tests
L.DEBUG_ON          = "debug mode ON: addon messages are shown in chat. Type /ghub debug again to turn it off."
L.DEBUG_OFF         = "debug mode OFF."
L.TEST_SENDING      = "sending a %d-character test message in %d pieces..."
L.TEST_OK           = "test message from %s: %d characters received OK."
L.TEST_BAD          = "test message from %s arrived damaged (%d of %d characters)."
L.TEST_WAIT         = "please wait a few seconds before the next test."

-- Notes
L.UPDATE_AVAILABLE  = "a newer version (%s) is available. You have %s. It keeps working, but please update when you can."
L.TRIAL_NOTE        = "trial and Veteran accounts can't send addon messages, so your info won't be shared with the guild. You can still see what others share."
L.LOCKDOWN_PAUSED   = "messages paused (boss fight or PvP match); they will be sent afterwards."

-- Options
L.OPT_TITLE         = "Guild Hub"
L.OPT_INTRO         = "Guild Hub shares what you are doing with your guildmates who also have Guild Hub. More settings arrive with professions and the map."
L.OPT_DEBUG         = "Debug mode"
L.OPT_DEBUG_DESC    = "Show every addon message that is sent or received in the chat window."
L.OPT_OFFICER_HDR   = "Officer ranks"
L.OPT_OFFICER       = "Officers are ranks up to and including"
L.OPT_OFFICER_DESC  = "Only the Guild Master can change this. It is shared with everyone in the guild who has Guild Hub."
L.OPT_OFFICER_SET   = "officer ranks set: up to and including \"%s\"."
L.OPT_NOT_GM        = "Set by the Guild Master. Current setting: up to and including \"%s\"."

L.OPT_BOARD_HDR     = "Status board"
L.OPT_AUTOACT       = "Share my activity automatically"
L.OPT_AUTOACT_DESC  = "Shares your current activity (dungeon, gathering, AFK...) with your guild. Turn it off to share only the status you pick yourself."
L.OPT_ALERT_LFG     = "LFG notes"
L.OPT_ALERT_LFG_DESC = "Show a small note when a guildmate within 5 levels of you starts looking for a group."
L.OPT_ALERT_HELP    = "Need help notes"
L.OPT_ALERT_HELP_DESC = "Show a small note when a guildmate asks for help."
L.OPT_MUTED         = "Muted players (untick to unmute)"
L.OPT_MUTED_DESC    = "You get no notes from these players, and their own status text is hidden on the board."
L.OPT_MUTED_NONE    = "Nobody is muted. Use the Mute button on a note to mute someone."
L.OPT_MINIMAP       = "Hide the minimap button"
L.OPT_NOADDON       = "Show online guildmates without Guild Hub (greyed out)"
L.OPT_SHAREGROUP    = "Share my group size"
L.OPT_SHAREGROUP_DESC = "Shows guildmates with Guild Hub how many players are in your party or raid (only the number, no names). Turn it off to share nothing about your group."

-- Window and status board
L.WIN_TITLE         = "Guild Hub"
L.WIN_SUB           = "/ghub · status board"
L.TAB_STATUS        = "Status"
L.TAB_SETTINGS      = "Settings"
L.WIN_SUB_SETTINGS  = "/ghub · settings"
L.MINI_TIP          = "Mini mode: a small window with just what your guildmates are doing"
L.MINI_BACK_TIP     = "Back to the full Guild Hub window"
L.MINI_ONLINE       = "%d online with Guild Hub"
L.MINI_EMPTY        = "Nobody else with Guild Hub is online."
L.MINI_MORE         = "Scroll for %d more"
L.MINI_CLICK        = "Click: whisper"
L.SEARCH_HINT       = "Search name, zone, rank or status"
L.SORT_FMT          = "Sort: %s"
L.SORT = { activity = "Activity", level = "Level", zone = "Zone", rank = "Rank", name = "Name" }
L.COL_RANK          = "RANK"
L.SORT_TIP          = "Left-click: next · Right-click: previous"
L.COMPACT_TIP       = "Show only players looking for a group"
L.FOR_FMT           = "for %s"
L.TIP_FOR_CLEARS    = "for %s · clears in %s"
L.NOTE_UNSENT       = "Press Enter to share"
L.MM_TIP_LFG        = "%d looking for group"
L.MM_TIP_HELP1      = "%d needs help"
L.MM_TIP_HELPN      = "%d need help"
L.COMPACT           = "Compact: LFG only"
L.COL_NAME, L.COL_LVL, L.COL_ZONE, L.COL_STATUS, L.COL_TIME, L.COL_ACTIONS = "NAME", "LVL", "ZONE", "STATUS", "TIME", "ACTIONS"
L.COL_GROUP         = "GROUP"
L.GRP_YOURS         = "Yours"
L.GRP_PARTY         = "%d/5"
L.GRP_RAID          = "R %d"
L.TIP_GRP_YOURS     = "In your group (%s)"
L.TIP_GRP_YOURS_PLAIN = "In your group"
L.TIP_GRP_PARTY     = "In a party of %d"
L.TIP_GRP_RAID      = "In a raid (%d)"
L.TIP_GRP_SOLO      = "Not in a group"
L.INVITE_IN_GROUP   = "Already in your group"
L.ACT_IN_FMT        = "%s: %s" -- "In a dungeon: RFC"
L.BTN_WHISPER       = "Whisper"
L.BTN_INVITE        = "Invite"
L.BTN_MUTE          = "Mute"
L.BTN_CLEAR         = "Clear"
L.FOOTER            = "%d online · %d with Guild Hub"
L.FOOTER_RIGHT      = "Statuses clear after the time picked (1-8 h)"
L.LASTS_FMT         = "Lasts: %d h"
L.LASTS_TIP         = "How long your status stays up (1, 2, 4 or 8 hours). Left-click: longer · Right-click: shorter. Every new status starts at 1 hour."
L.EMPTY_LIST        = "Nobody to show."
L.YOUR_STATUS       = "Your status"
L.NOTE_HINT         = "Short note (Enter to share)"
L.DUNGEON_FMT       = "Dungeon: %s"
L.CLEARS_IN         = "Clears in %s"
L.NO_STATUS         = "No status set"
L.AUTO_ACT_FMT      = "Automatic activity: %s"
L.AUTO_ACT_NONE     = "nothing special"
L.AUTO_ACT_OFF      = "Automatic activity: off (see settings)"
L.LFG_ANY           = "Any dungeon"
L.NO_ADDON_ROW      = "(no Guild Hub)"
L.TIP_LEVEL_ZONE    = "Level %s · %s"
L.MM_TIP_CLICK      = "Click: open/close · Right-click: settings · Drag: move"

L.PRESET = { lfg = "LFG", help = "Need help", farm = "Farming", lvl = "Leveling", busy = "Busy", chat = "Open to chat" }
L.ACT = {
	afk = "AFK", dng = "In a dungeon", raid = "In a raid", pvp = "In PvP", gath = "Gathering", fish = "Fishing",
	quest = "Questing", lvl = "Leveling", town = "In town", inn = "At an inn",
}
L.GROUP = {
	lfg = "Looking for group", help = "Need help", dungeon = "In dungeons and raids", farm = "Farming and questing",
	town = "In town or at an inn", busy = "Busy or AFK", other = "Other", noaddon = "Online without Guild Hub",
}

-- Alerts (chat line + small note; never sent to anyone)
L.TOAST_TITLE       = "Guild Hub:"
L.ALERT_LFG         = "%s (%s) is looking for a group: %s"
L.ALERT_HELP        = "%s needs help: %s"
L.ALERT_HELP_PLAIN  = "%s needs help."
L.MUTED             = "%s is muted: no more notes from them, and their status text is hidden. Unmute in /ghub options."
L.STATUS_EXPIRED    = "your status was cleared (its time was up)."
L.INVITE_FALLBACK   = "the game didn't let Guild Hub invite directly, so \"/invite\" is put in your chat box instead: press Enter to send it."

-- Tests
L.TEST_ACTIVITY     = "activity: %s · auto sharing %s · last spell ID %s · quest turned in %s · XP gained %s · resting %s · instance %s · instance ID %s"
L.TEST_EXPIRE       = "your status now looks older than its time; it should clear within 30 seconds."
L.TEST_EXPIRE_NONE  = "you have no status set. Pick one first (open /ghub)."
L.YES, L.NO, L.NEVER = "yes", "no", "never"
L.AGO               = "%s ago"

-- Time
L.T_DAYS            = "%d d"
L.T_HOURS           = "%d h"
L.T_MINUTES         = "%d min"
L.T_HOURS_MIN       = "%d h %d min"
L.T_LESS_MIN        = "<1 min"
L.T_JUSTNOW         = "less than a minute"
