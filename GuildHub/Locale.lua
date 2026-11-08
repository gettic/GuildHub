-- Guild Hub: all text the player can see, in one place (English only for now).
local _, ns = ...

local L = {}
ns.L = L

L.PREFIX            = "|cff33ccffGuild Hub:|r "
L.DEBUG_PREFIX      = "|cff33ccffGuild Hub:|r |cff888888[debug]|r "

-- /ghub help
L.HELP_HEADER       = "commands:"
L.HELP_STATUS       = "  /ghub status - who has Guild Hub and which version"
L.HELP_DEBUG        = "  /ghub debug - show addon messages as they are sent and received (on/off)"
L.HELP_TEST         = "  /ghub test big - send one long test message to check splitting"
L.HELP_OPTIONS      = "  /ghub options - open the settings"

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
L.OPT_INTRO         = "Guild Hub shares what you are doing with your guildmates who also have Guild Hub. More settings arrive with the status board, professions and map."
L.OPT_DEBUG         = "Debug mode"
L.OPT_DEBUG_DESC    = "Show every addon message that is sent or received in the chat window."
L.OPT_OFFICER_HDR   = "Officer ranks"
L.OPT_OFFICER       = "Officers are ranks up to and including"
L.OPT_OFFICER_DESC  = "Only the Guild Master can change this. It is shared with everyone in the guild who has Guild Hub."
L.OPT_OFFICER_SET   = "officer ranks set: up to and including \"%s\"."
L.OPT_NOT_GM        = "Set by the Guild Master. Current setting: up to and including \"%s\"."

-- Time
L.T_DAYS            = "%d d"
L.T_HOURS           = "%d h"
L.T_MINUTES         = "%d min"
L.T_JUSTNOW         = "less than a minute"
