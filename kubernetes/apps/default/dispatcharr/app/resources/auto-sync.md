# Auto Sync

## DIRTVision

### Groups

#### Find/Replace

Regex: `^[Dd][Ii][Rr][Tt][Vv][Ii][Ss][Ii][Oo][Nn]\s+0[1-9]\s*:\s*(.+?)\s+(\d{1,2}:\d{2}\s*[AaPp][Mm])\s*$`

Replace: `$1`

#### Include Match

Regex: `^[Dd][Ii][Rr][Tt][Vv][Ii][Ss][Ii][Oo][Nn]\s+0[1-9]\s*:\s+\S.*$`

### EPG (AutoSync)

#### Pattern Configuration

Name Source: Stream Name

Stream Index: 1

Title Pattern Regex: `DIRTVISION\s\d+\s*:\s*(?<event>.+?)\s+(?<hour>\d{1,2}):(?<minute>\d{2})\s*(?<ampm>[AaPp][Mm])`

Time Pattern Regex: `(?<hour>\d{1,2}):(?<minute>\d{2})\s*(?<ampm>[AaPp][Mm])`

Date Pattern Regex: `N/A`

#### Output Templates

Title Template: `{event}`

Subtitle Template: `{event}`

Description Template: `Started at {starttime}. Event completing by {endtime}. ({month}/{day}/{year})`

#### Upcoming/Ended Templates

Upcoming Title Template: `UPCOMING: {event} starting at {starttime}`

Upcoming Description Template: `{event} starting at {starttime}.`

Ended Title Template: `ENDED: {event}`

Ended Description Template: `{event} ended at {endtime}.`

#### Fallback Templates

Fallback Title Template: `OFFLINE`

Fallback Description Template: `OFFLINE`

#### EPG Settings

Event Timezone: `US/Eastern`

Output Timezone: `US/Central`

Program Duration: `480`

Categories: `N/A`

Channel Logo URL: `N/A`

Program Post URL: `https://i.imgur.com/vjya8rn.jpeg`

[x] Include Date Tag

[x] Include Live Tag

[x] Include New Tag

### EPG (24/7)

#### Pattern Configuration

Name Source: Channel Name

Title Pattern Regex: `^(?<event>DIRTVision Now 24/7)$`

Time Pattern Regex: `N/A`

Date Pattern Regex: `N/A`

#### Output Templates

Title Template: `{event}`

Subtitle Template: `N/A`

Description Template: `{event}`

#### Upcoming/Ended Templates

Upcoming Title Template: `UPCOMING: {event}`

Upcoming Description Template: `N/A`

Ended Title Template: `ENDED: {event}`

Ended Description Template: `N/A`

#### Fallback Templates

Fallback Title Template: `DIRTVision Now 24/7`

Fallback Description Template: `DIRTVision Now 24/7`

#### EPG Settings

Event Timezone: `US/Eastern`

Output Timezone: `US/Central`

Program Duration: `1440`

Categories: `N/A`

Channel Logo URL: `N/A`

Program Post URL: `https://i.imgur.com/vjya8rn.jpeg`

[x] Include Date Tag

[x] Include Live Tag

[x] Include New Tag

## FloRacing

### Groups

#### Find/Replace

Regex: `^(.+?)(?=\s+@\s+.+\s+:Flo Racing\s+\d{2}$|\s+:Flo Racing\s+\d{2}$).*$`

Replace: `$1`

#### Include Match

Regex: `^(?!.*(?:PBR RidePass|FloRacing 24(?: 7|\/7))).+ @ [A-Z][a-z]{2} \d{1,2} \d{1,2}:\d{2} (?:AM|PM) :Flo Racing\s+(?:0[1-9]|1[0-9])$`

### EPG (AutoSync)

#### Pattern Configuration

Name Source: Stream Name

Stream Index: 1

Title Pattern Regex: `^(?<event>.+?)(?=\s+@\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{1,2}:\d{2}\s+(?:AM|PM)\s+:\s*Flo Racing\s+\d{2}$|\s+:\s*Flo Racing\s+\d{2}$)(?:\s+@\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{1,2}:\d{2}\s+(?:AM|PM))?\s+:\s*Flo Racing\s+\d{2}$`

Time Pattern Regex: `(?<=\s)(?<hour>\d{1,2}):(?<minute>\d{2})\s+(?<ampm>AM|PM)(?=\s+:)`

Date Pattern Regex: `(?<=@\s)(?<month>[A-Za-z]{3})\s+(?<day>\d{1,2})`

#### Output Templates

Title Template: `{event}`

Subtitle Template: `{event}`

Description Template: `Started at {starttime}. Event completing by {endtime}. ({month}/{day}/{year})`

#### Upcoming/Ended Templates

Upcoming Title Template: `UPCOMING: {event} starting at {starttime}`

Upcoming Description Template: `{event} starting at {starttime}.`

Ended Title Template: `ENDED: {event}`

Ended Description Template: `{event} ended at {endtime}.`

#### Fallback Templates

Fallback Title Template: `OFFLINE`

Fallback Description Template: `OFFLINE`

#### EPG Settings

Event Timezone: `US/Eastern`

Output Timezone: `US/Central`

Program Duration: `480`

Categories: `N/A`

Channel Logo URL: `N/A`

Program Post URL: `https://i.imgur.com/5cscekP.jpeg`

[x] Include Date Tag

[x] Include Live Tag

[x] Include New Tag

### EPG (24/7)

#### Pattern Configuration

Name Source: Channel Name

Title Pattern Regex: `^(?<event>FloRacing 24\/7|PBR RidePass)$`

Time Pattern Regex: `N/A`

Date Pattern Regex: `N/A`

#### Output Templates

Title Template: `{event}`

Subtitle Template: `N/A`

Description Template: `{event}`

#### Upcoming/Ended Templates

Upcoming Title Template: `UPCOMING: {event}`

Upcoming Description Template: `N/A`

Ended Title Template: `ENDED: {event}`

Ended Description Template: `N/A`

#### Fallback Templates

Fallback Title Template: `{event}`

Fallback Description Template: `{event}`

#### EPG Settings

Event Timezone: `US/Eastern`

Output Timezone: `US/Central`

Program Duration: `1440`

Categories: `N/A`

Channel Logo URL: `N/A`

Program Post URL: `https://i.imgur.com/vjya8rn.jpeg`

[x] Include Date Tag

[x] Include Live Tag

[x] Include New Tag
