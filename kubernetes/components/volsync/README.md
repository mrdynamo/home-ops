# Volsync

## Replication Sources

| Workload             | Size  | Volsync Replication Schedule | Crontab (UTC)   | Crontab (CST -5)   | Crontab (CDT -6)   |
|----------------------|-------|------------------------------|-----------------|--------------------|--------------------|
| atuin                | 1 Gi  | Tuesday @ 09:00              | `0 9 * * 2`     | `0 14 * * 2`       | `0 15 * * 2`       |
| bazarr               | 1 Gi  | Wednesday @ 10:00            | `0 10 * * 3`    | `0 15 * * 3`       | `0 16 * * 3`       |
| channel-identifiarr  | 1 Gi  | Tuesday @ 10:00              | `0 10 * * 2`    | `0 15 * * 2`       | `0 16 * * 2`       |
| emby                 | 8 Gi  | Monday @ 10:00               | `0 10 * * 1`    | `0 15 * * 1`       | `0 16 * * 1`       |
| dispatcharr          | 1 Gi  | Friday @ 10:00               | `0 10 * * 5`    | `0 15 * * 5`       | `0 16 * * 5`       |
| homepage             | 1 Gi  | Thursday @ 04:00             | `0 4 * * 4`     | `0 9 * * 4`        | `0 10 * * 4`       |
| invoice-nina         | 1 Gi  | Wednesday @ 12:00            | `0 12 * * 3`    | `0 17 * * 3`       | `0 18 * * 3`       |
| kometa               | 6 Gi  | Thursday @ 05:00             | `0 5 * * 4`     | `0 10 * * 4`       | `0 11 * * 4`       |
| lubelogger           | 1 Gi  | Monday @ 13:00               | `0 13 * * 1`    | `0 18 * * 1`       | `0 19 * * 1`       |
| maintainerr          | 1 Gi  | Tuesday @ 08:00              | `0 8 * * 2`     | `0 13 * * 2`       | `0 14 * * 2`       |
| mealie               | 1 Gi  | Thursday @ 06:00             | `0 6 * * 4`     | `0 11 * * 4`       | `0 12 * * 4`       |
| open-webui           | 2 Gi  | Thursday @ 08:00             | `0 8 * * 4`     | `0 13 * * 4`       | `0 14 * * 4`       |
| paperless            | 2 Gi  | Friday @ 11:00               | `0 11 * * 5`    | `0 16 * * 5`       | `0 17 * * 5`       |
| paperless-ai         | 2 Gi  | Friday @ 11:00               | `0 11 * * 5`    | `0 16 * * 5`       | `0 17 * * 5`       |
| pgamdin              | 1 Gi  | Tuesday @ 11:00              | `0 11 * * 2`    | `0 16 * * 2`       | `0 17 * * 2`       |
| plex                 | 18 Gi | Monday @ 07:00               | `0 7 * * 1`     | `0 12 * * 1`       | `0 13 * * 1`       |
| prowlarr             | 1 Gi  | Thursday @ 07:00             | `0 7 * * 4`     | `0 12 * * 4`       | `0 13 * * 4`       |
| radarr               | 4 Gi  | Wednesday @ 08:00            | `0 8 * * 3`     | `0 13 * * 3`       | `0 14 * * 3`       |
| sabnzbd              | 1 Gi  | Tuesday @ 06:00              | `0 6 * * 2`     | `0 11 * * 2`       | `0 12 * * 2`       |
| seerr                | 1 Gi  | Tuesday @ 04:00              | `0 4 * * 2`     | `0 9 * * 2`        | `0 10 * * 2`       |
| sonarr               | 4 Gi  | Wednesday @ 04:00            | `0 4 * * 3`     | `0 9 * * 3`        | `0 10 * * 3`       |
| syncthing            | 1 Gi  | Monday @ 12:00               | `0 12 * * 1`    | `0 17 * * 1`       | `0 18 * * 1`       |
| tautulli             | 4 Gi  | Friday @ 04:00               | `0 4 * * 5`     | `0 9 * * 5`        | `0 10 * * 5`       |
| teamarr              | 1 Gi  | Tuesday @ 10:00              | `0 10 * * 2`    | `0 15 * * 2`       | `0 16 * * 2`       |
| wizarr               | 1 Gi  | Friday @ 08:00               | `0 8 * * 5`     | `0 13 * * 5`       | `0 14 * * 5`       |
| your-spotify         | 2 Gi  | Wednesday @ 11:00            | `0 11 * * 3`    | `0 16 * * 3`       | `0 17 * * 3`       |
