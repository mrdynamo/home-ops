#  -*- coding: utf-8 -*-

import logging
from colorama import Fore
from TwitchChannelPointsMiner import TwitchChannelPointsMiner
from TwitchChannelPointsMiner.logger import LoggerSettings, ColorPalette
from TwitchChannelPointsMiner.classes.Chat import ChatPresence
from TwitchChannelPointsMiner.classes.Discord import Discord
from TwitchChannelPointsMiner.classes.Telegram import Telegram
from TwitchChannelPointsMiner.classes.Settings import Priority, Events, FollowersOrder
from TwitchChannelPointsMiner.classes.entities.Bet import (
    Strategy,
    BetSettings,
    Condition,
    OutcomeKeys,
    FilterCondition,
    DelayMode,
)
from TwitchChannelPointsMiner.classes.entities.Streamer import (
    Streamer,
    StreamerSettings,
)

## Get Environment Variables
import os

TWITCH_USERNAME = os.environ.get("TWITCH_USERNAME")
DISCORD_WEBHOOK = os.environ.get("DISCORD_WEBHOOK")
DISCORD_CHAT_MENTION_WEBHOOK = os.environ.get("DISCORD_CHAT_MENTION_WEBHOOK")

twitch_miner = TwitchChannelPointsMiner(
    username=TWITCH_USERNAME,
    password="",  # If no password will be provided, the script will ask interactively
    claim_drops_startup=True,  # If you want to auto claim all drops from Twitch inventory on the startup
    priority=[  # Custom priority in this case for example:
        Priority.STREAK,  # - We want first of all to catch all watch streak from all streamers
        Priority.DROPS,  # - When we don't have anymore watch streak to catch, wait until all drops are collected over the streamers
        Priority.ORDER,  # - When we have all of the drops claimed and no watch-streak available, use the order priority (POINTS_ASCENDING, POINTS_DESCEDING)
    ],
    enable_analytics=True,
    disable_at_in_nickname=True,
    logger_settings=LoggerSettings(
        save=True,  # If you want to save logs in a file (suggested)
        console_level=logging.INFO,  # Level of logs - use logging.DEBUG for more info
        file_level=logging.INFO,  # Level of logs - If you think the log file it's too big, use logging.INFO
        time_zone="America/Chicago",  # Timezone for the log timestamps
        emoji=True,  # On Windows, we have a problem printing emoji. Set to false if you have a problem
        less=False,  # If you think that the logs are too verbose, set this to True
        colored=True,  # If you want to print colored text
        color_palette=ColorPalette(  # You can also create a custom palette color (for the common message).
            STREAMER_ONLINE=Fore.GREEN,
            STREAMER_OFFLINE=Fore.RED,
            GAIN_FOR_RAID=Fore.YELLOW,
            GAIN_FOR_CLAIM=Fore.YELLOW,
            GAIN_FOR_WATCH=Fore.YELLOW,
            GAIN_FOR_WATCH_STREAK=Fore.YELLOW,
            BET_WIN=Fore.GREEN,
            BET_LOSE=Fore.RED,
            BET_REFUND=Fore.RESET,
            BET_FILTERS=Fore.MAGENTA,
            BET_GENERAL=Fore.BLUE,
            BET_FAILED=Fore.RED,
        ),
        hooks=[
            Discord(
                webhook_api=DISCORD_WEBHOOK,  # Discord Webhook URL
                events=[
                    Events.STREAMER_ONLINE,
                    Events.STREAMER_OFFLINE,
                    Events.GAIN_FOR_RAID,
                    Events.GAIN_FOR_CLAIM,
                    Events.GAIN_FOR_WATCH,
                    Events.GAIN_FOR_WATCH_STREAK,
                    Events.BET_WIN,
                    Events.BET_LOSE,
                    Events.BET_REFUND,
                    Events.BET_FILTERS,
                    Events.BET_GENERAL,
                    Events.BET_FAILED,
                    Events.BET_START,
                    Events.BONUS_CLAIM,
                    Events.MOMENT_CLAIM,
                    Events.JOIN_RAID,
                    Events.DROP_CLAIM,
                    Events.DROP_STATUS,
                ],  # Only these events will be sent to the chat
            ),
            Discord(
                webhook_api=DISCORD_CHAT_MENTION_WEBHOOK,  # Discord Chat Mention Webhook URL
                events=[
                    Events.CHAT_MENTION,
                ],  # Only these events will be sent to the chat
            ),
        ],
    ),
    streamer_settings=StreamerSettings(
        make_predictions=False,  # If you want to Bet / Make prediction
        follow_raid=True,  # Follow raid to obtain more points
        claim_drops=True,  # We can't filter rewards base on stream. Set to False for skip viewing counter increase and you will never obtain a drop reward from this script. Issue #21
        claim_moments=True,  # Automatically claim moments
        watch_streak=True,  # If a streamer go online change the priority of streamers array and catch the watch screak. Issue #11
        chat=ChatPresence.ALWAYS,  # Join irc chat to increase watch-time [ALWAYS, NEVER, ONLINE, OFFLINE]
        bet=BetSettings(
            strategy=Strategy.SMART,  # Choose you strategy!
            percentage=5,  # Place the x% of your channel points
            percentage_gap=20,  # Gap difference between outcomesA and outcomesB (for SMART strategy)
            max_points=50000,  # If the x percentage of your channel points is gt bet_max_points set this value
            stealth_mode=True,  # If the calculated amount of channel points is GT the highest bet, place the highest value minus 1-2 points Issue #33
            delay_mode=DelayMode.FROM_END,  # When placing a bet, we will wait until `delay` seconds before the end of the timer
            delay=6,
            minimum_points=20000,  # Place the bet only if we have at least 20k points. Issue #113
            filter_condition=FilterCondition(
                by=OutcomeKeys.TOTAL_USERS,  # Where apply the filter. Allowed [PERCENTAGE_USERS, ODDS_PERCENTAGE, ODDS, TOP_POINTS, TOTAL_USERS, TOTAL_POINTS]
                where=Condition.LTE,  # 'by' must be [GT, LT, GTE, LTE] than value
                value=800,
            ),
        ),
    ),
)

# Enable analytics webpage

twitch_miner.analytics(host="0.0.0.0", port=5000, refresh=5, days_ago=180)

# You can customize the settings for each streamer. If not settings were provided, the script would use the streamer_settings from TwitchChannelPointsMiner.
# If no streamer_settings are provided in TwitchChannelPointsMiner the script will use default settings.
# The streamers array can be a String -> username or Streamer instance.

# The settings priority are: settings in mine function, settings in TwitchChannelPointsMiner instance, default settings.
# For example, if in the mine function you don't provide any value for 'make_prediction' but you have set it on TwitchChannelPointsMiner instance, the script will take the value from here.
# If you haven't set any value even in the instance the default one will be used

twitch_miner.mine(
    [
        Streamer("g3trail3d"),
        Streamer("quirkitized"),
        Streamer("mattmalone"),
        Streamer("scump"),
        Streamer("datmodz"),
        Streamer("slr0x"),
        # Streamer("huntthefrontgaming"),
        Streamer("jesseenterkin25"),
        Streamer("mummkey"),
        Streamer("jokehow"),
        # Streamer("saggdad"),
        Streamer("trinityviolette"),
        Streamer("saltyteemo"),
    ],  # Array of streamers (order = priority)
    followers=False,  # Automatic download the list of your followers
    followers_order=FollowersOrder.ASC,  # Sort the followers list by follow date (ASC or DESC)
)
