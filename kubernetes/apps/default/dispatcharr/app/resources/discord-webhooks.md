
# Webhook Templates - Discord

This document contains the Dispatcharr webhook templates (Jinja/Django-style) formatted for Discord `content` payloads. Copy the matching code block into your Dispatcharr webhook configuration for the corresponding event.

## Documentation

- Templates use Django/Jinja syntax and are rendered by Dispatcharr.
- Each block is a standalone JSON `content` string suitable for Discord webhooks.
- Use `escapejs` to keep rendered values safe inside JSON strings.
- Important privacy rules:
  - `channel_url` MUST NOT be included in templates or payload examples.
  - `stream_url` MUST NOT be included in templates or payload examples.
- Username defaults: the templates use `Anonymous` when no username is provided.
- Formatting conventions used in these templates:
  - Event title: bold + underline with emojis outside the decorated title.
  - Labels: bold on their own line.
  - Values: italicized on the following line.

---

## Channel Started (event: `channel_start`)

```jinja
{
	"content": "\n▶️ **__Channel Started__** ▶️\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Stream:**\n*{{ stream_name|default:'Unknown stream'|escapejs }}*\n**Provider:**\n*{{ provider_name|default:'Unknown provider'|escapejs }}*\n**Profile:**\n*{{ profile_used|default:'Default'|escapejs }}*\n**Stream ID:**\n*{{ stream_id|default:'n/a'|escapejs }}*"
}
```

## Channel Stopped (event: `channel_stop`)

```jinja
{% with runtime_seconds=runtime|default:0 bytes_total=total_bytes|default:0 %}
{% widthratio runtime_seconds 60 1 as runtime_minutes %}
{% widthratio bytes_total 1048576 1 as total_megabytes %}
{
	"content": "\n⏹️ **__Channel Stopped__** ⏹️\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Runtime:**\n*{{ runtime_minutes|escapejs }} min*\n**Total Data:**\n*{{ total_megabytes|escapejs }} MB*"
}
{% endwith %}
```

## Channel Reconnected (event: `channel_reconnect`)

```jinja
{
	"content": "\n🔁 **__Channel Reconnected__** 🔁\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Stream:**\n*{{ stream_name|default:'Unknown stream'|escapejs }}*\n**Provider:**\n*{{ provider_name|default:'Unknown provider'|escapejs }}*\n**Reason:**\n*{{ reason|default:'Automatic recovery'|escapejs }}*"
}
```

## Channel Error (event: `channel_error`)

```jinja
{
	"content": "\n⚠️ **__Channel Error__** ⚠️\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Stream:**\n*{{ stream_name|default:'Unknown stream'|escapejs }}*\n**Provider:**\n*{{ provider_name|default:'Unknown provider'|escapejs }}*\n**Error:**\n*{{ error|default:reason|default:message|default:'Unknown error'|escapejs }}*"
}
```

## Channel Failover (event: `channel_failover`)

```jinja
{% with duration_seconds=duration|default:0 %}
{% widthratio duration_seconds 60 1 as duration_minutes %}
{
	"content": "\n🔀 **__Channel Failover__** 🔀\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Current Stream:**\n*{{ stream_name|default:'Unknown stream'|escapejs }}*\n**Provider:**\n*{{ provider_name|default:'Unknown provider'|escapejs }}*\n**Reason:**\n*{{ reason|default:'Automatic failover'|escapejs }}*\n**Duration:**\n*{{ duration_minutes|escapejs }} min*"
}
{% endwith %}
```

## Stream Switch (event: `stream_switch`)

```jinja
{
	"content": "\n🔀 **__Stream Switch__** 🔀\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Active Stream:**\n*{{ stream_name|default:'Unknown stream'|escapejs }}*\n**Stream ID:**\n*{{ stream_id|default:'n/a'|escapejs }}*\n**Provider:**\n*{{ provider_name|default:'Unknown provider'|escapejs }}*\n**Profile:**\n*{{ profile_used|default:'Default'|escapejs }}*"
}
```

## Recording Started (event: `recording_start`)

```jinja
{
	"content": "\n⏺️ **__Recording Started__** ⏺️\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Recording ID:**\n*{{ recording_id|default:'n/a'|escapejs }}*\n**Profile:**\n*{{ profile_used|default:'Default'|escapejs }}*\n**Stream:**\n*{{ stream_name|default:'Unknown stream'|escapejs }}*"
}
```

## Recording Ended (event: `recording_end`)

```jinja
{% with bytes_total=bytes_written|default:0 %}
{% widthratio bytes_total 1048576 1 as total_megabytes %}
{
	"content": "\n⏹️ **__Recording Ended__** ⏹️\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Recording ID:**\n*{{ recording_id|default:'n/a'|escapejs }}*\n**Interrupted:**\n*{{ interrupted|default:'false'|escapejs }}*\n**Data Written:**\n*{{ total_megabytes|escapejs }} MB*\n**Reason:**\n*{{ interrupted_reason|default:reason|default:'Normal completion'|escapejs }}*"
}
{% endwith %}
```

## EPG Refreshed (event: `epg_refresh`)

```jinja
{
	"content": "\n🔄 **__EPG Refreshed__** 🔄\n**Source:**\n*{{ source_name|default:'Unknown source'|escapejs }}*\n**Channels:**\n*{{ channels|default:'0'|escapejs }}*\n**Programs:**\n*{{ programs|default:'0'|escapejs }}*\n**Skipped Programs:**\n*{{ skipped_programs|default:'0'|escapejs }}*\n**Status:**\n*{{ status|default:'success'|escapejs }}*\n**Details:**\n*{{ message|default:last_message|default:'EPG refresh completed'|escapejs }}*"
}
```

## M3U Refreshed (event: `m3u_refresh`)

```jinja
{
	"content": "\n🔄 **__M3U Refreshed__** 🔄\n**Account:**\n*{{ account_name|default:'Unknown account'|escapejs }}*\n**Created:**\n*{{ streams_created|default:'0'|escapejs }}*\n**Updated:**\n*{{ streams_updated|default:'0'|escapejs }}*\n**Deleted:**\n*{{ streams_deleted|default:'0'|escapejs }}*\n**Total Processed:**\n*{{ total_processed|default:streams_processed|default:'0'|escapejs }}*\n**Elapsed Time:**\n*{{ elapsed_time|default:'n/a'|escapejs }}*"
}
```

## Client Connected (event: `client_connect`)

```jinja
{
	"content": "\n🔌 **__Client Connected__** 🔌\n**Username:**\n*{{ username|default:'Anonymous'|escapejs }}*\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Client ID:**\n*{{ client_id|default:'n/a'|escapejs }}*\n**IP Address:**\n*{{ client_ip|default:'Unknown'|escapejs }}*\n**User Agent:**\n*{{ user_agent|default:'Unknown'|escapejs }}*"
}
```

## Client Disconnected (event: `client_disconnect`)

```jinja
{% with duration_seconds=duration|default:0 bytes_total=bytes_sent|default:0 %}
{% widthratio duration_seconds 60 1 as duration_minutes %}
{% widthratio bytes_total 1048576 1 as total_megabytes %}
{
	"content": "\n❌ **__Client Disconnected__** ❌\n**Username:**\n*{{ username|default:'Anonymous'|escapejs }}*\n**Channel:**\n*{{ channel_name|default:'Unknown channel'|escapejs }}*\n**Client ID:**\n*{{ client_id|default:'n/a'|escapejs }}*\n**IP Address:**\n*{{ client_ip|default:'Unknown'|escapejs }}*\n**Duration:**\n*{{ duration_minutes|escapejs }} min*\n**Data Sent:**\n*{{ total_megabytes|escapejs }} MB*\n**User Agent:**\n*{{ user_agent|default:'Unknown'|escapejs }}*"
}
{% endwith %}
```

## Login Failed (event: `login_failed`)

```jinja
{
	"content": "\n🔒 **__Login Failed__** 🔒\n**User:**\n*{{ user|default:username|default:'Anonymous'|escapejs }}*\n**IP Address:**\n*{{ client_ip|default:ip_address|default:'Unknown'|escapejs }}*\n**User Agent:**\n*{{ user_agent|default:'Unknown'|escapejs }}*\n**Reason:**\n*{{ reason|default:error|default:message|default:'Invalid credentials'|escapejs }}*"
}
```

## EPG Blocked (event: `epg_blocked`)

```jinja
{
	"content": "\n🚫 **__EPG Blocked__** 🚫\n**User:**\n*{{ user|default:username|default:'Anonymous'|escapejs }}*\n**Profile:**\n*{{ profile|default:'all'|escapejs }}*\n**IP Address:**\n*{{ client_ip|default:ip_address|default:'Unknown'|escapejs }}*\n**Reason:**\n*{{ reason|default:error|default:message|default:'Request blocked'|escapejs }}*\n**User Agent:**\n*{{ user_agent|default:'Unknown'|escapejs }}*"
}
```

## M3U Blocked (event: `m3u_blocked`)

```jinja
{
	"content": "\n🚫 **__M3U Blocked__** 🚫\n**User:**\n*{{ user|default:username|default:'Anonymous'|escapejs }}*\n**Profile:**\n*{{ profile|default:'all'|escapejs }}*\n**IP Address:**\n*{{ client_ip|default:ip_address|default:'Unknown'|escapejs }}*\n**Reason:**\n*{{ reason|default:error|default:message|default:'Request blocked'|escapejs }}*\n**User Agent:**\n*{{ user_agent|default:'Unknown'|escapejs }}*"
}
```

