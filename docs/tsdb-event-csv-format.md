# TheSportsDB Event CSV Format

The CSV schema consumed by [`scripts/tsdb-update-events.sh`](../scripts/tsdb-update-events.sh). Use this doc to feed an LLM a race-weekend schedule and have it produce a CSV you can pass to the script.

## Purpose

1. Give an LLM a natural-language schedule for a race weekend.
2. The LLM emits a CSV matching this schema.
3. Run `scripts/tsdb-update-events.sh --csv events.csv` to POST each row to TheSportsDB's `eventschedule_edit.php` endpoint.

Teamarr reads those events and creates per-session channels in Dispatcharr.

## CSV Schema

### Required columns

| Column | Format | Example |
|---|---|---|
| `strEvent` | `<Round> <Session>` (single-class) or `<Round> <Session> - <Class>` (multi-class) | `6 Hours of Barcelona Free Practice 3 - LMGT3` |
| `dateEvent` | `YYYY-MM-DD` (local to venue) | `2026-10-16` |
| `strTimeLocal` | `HH:MM:SS` 24-hour local time (use session **start**) | `11:30:00` |
| `strVenue` | Full official venue name | `Circuit de Barcelona-Catalunya` |

### Optional columns (with WEC defaults)

| Column | Default | Notes |
|---|---|---|
| `strCountry` | empty | Country name (e.g. `Spain`) |
| `strFilename` | empty | URL slug, e.g. `2026-wec-barcelona-fp1` |
| `idLeague` | `4413` | TSDB league ID (`4413` = WEC) |
| `strLeague` | `WEC` | League display name |
| `strSport` | `Motorsport` | Sport category |
| `strSeason` | `2026` | Season string |
| `intRound` | empty | Round number (e.g. `9`) |
| `idEvent` | empty | Leave blank to **insert**; set to an existing TSDB `idEvent` to **edit** |
| `timezone` | `Europe/Madrid` | IANA TZ name; the script uses this to compute UTC + epoch |

### Derived fields (computed by the script — never put these in the CSV)

- `strTime` (`HH:MM:SS` UTC)
- `strTimestamp` (Unix epoch seconds)

## Naming Convention

Match existing TSDB rounds verbatim. The operator's Fuji 2026 round uses this exact shape (verified):

- **Single-class sessions** (FP1, FP2, Race): no class suffix.
  ```
  6 Hours of Fuji
  6 Hours of Fuji Free Practice 1
  6 Hours of Fuji Free Practice 2
  ```

- **Multi-class sessions** (FP3, Qualifying, Hyperpole): use ` - ` (space-dash-space) as the class separator.
  ```
  6 Hours of Fuji Qualifying - LMGT3
  6 Hours of Fuji Qualifying - Hypercar
  6 Hours of Fuji Hyperpole - LMGT3
  6 Hours of Fuji Hyperpole - Hypercar
  ```

> **Never** use parentheses for the class (`... Qualifying (LMGT3)`). Teamarr's `racing.py` groups events by `strEvent` pattern; parentheses silently break the grouping regex.

## Worked Example: Barcelona WEC weekend

### Input (natural-language schedule, all times CEST = UTC+2)

> 6 Hours of Barcelona, FIA WEC round 9 at Circuit de Barcelona-Catalunya, Spain.
>
> **Friday Oct 16, 2026**
> - Free Practice 1: 11:30 – 13:00
> - Free Practice 2: 16:30 – 18:00
>
> **Saturday Oct 17, 2026**
> - Free Practice 3 (LMGT3): 08:50 – 09:50
> - Qualifying (LMGT3): 11:50 – 12:02
> - Hyperpole (LMGT3): 12:10 – 12:20
> - Free Practice 3 (Hypercar): 12:40 – 13:40
> - Qualifying (Hypercar): 15:40 – 15:52
> - Hyperpole (Hypercar): 16:00 – 16:10
>
> **Sunday Oct 18, 2026**
> - Race (6 Hours of Barcelona): 12:00 – 18:00

### Output CSV (copy-paste ready)

```csv
strEvent,dateEvent,strTimeLocal,strVenue,strCountry,strFilename,intRound,timezone
6 Hours of Barcelona Free Practice 1,2026-10-16,11:30:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-fp1,9,Europe/Madrid
6 Hours of Barcelona Free Practice 2,2026-10-16,16:30:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-fp2,9,Europe/Madrid
6 Hours of Barcelona Free Practice 3 - LMGT3,2026-10-17,08:50:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-fp3-lmgt3,9,Europe/Madrid
6 Hours of Barcelona Qualifying - LMGT3,2026-10-17,11:50:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-qual-lmgt3,9,Europe/Madrid
6 Hours of Barcelona Hyperpole - LMGT3,2026-10-17,12:10:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-hp-lmgt3,9,Europe/Madrid
6 Hours of Barcelona Free Practice 3 - Hypercar,2026-10-17,12:40:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-fp3-hypercar,9,Europe/Madrid
6 Hours of Barcelona Qualifying - Hypercar,2026-10-17,15:40:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-qual-hypercar,9,Europe/Madrid
6 Hours of Barcelona Hyperpole - Hypercar,2026-10-17,16:00:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-hp-hypercar,9,Europe/Madrid
6 Hours of Barcelona,2026-10-18,12:00:00,Circuit de Barcelona-Catalunya,Spain,2026-wec-barcelona-race,9,Europe/Madrid
```

## LLM Prompt Template

To convert a weekend schedule into this CSV, paste the following prompt verbatim, then append the schedule text:

````text
You are a motorsport scheduling assistant. Convert the race-weekend schedule I provide into a CSV file in TheSportsDB event format.

CSV columns (in this order, header row first):
strEvent,dateEvent,strTimeLocal,strVenue,strCountry,strFilename,intRound,timezone

Naming rules:
- Every strEvent must be prefixed with the round name (e.g. "6 Hours of Barcelona ...").
- Single-class sessions (Free Practice 1, Free Practice 2, the Race) take no class suffix.
- Multi-class sessions (Free Practice 3, Qualifying, Hyperpole) use " - " (space-dash-space) as the class separator. Example: "6 Hours of Barcelona Qualifying - LMGT3".
- Never use parentheses for the class.

Field rules:
- dateEvent: YYYY-MM-DD (local to venue)
- strTimeLocal: HH:MM:SS in 24-hour local time, use the session START time
- timezone: IANA TZ name (Europe/Madrid for CEST, Europe/Paris for CEST, Asia/Tokyo for JST, America/Sao_Paulo for BRT, etc.)
- strVenue: full official venue name (e.g. "Circuit de Barcelona-Catalunya")
- strCountry: country name (e.g. "Spain")
- strFilename: lowercase URL slug, format `<year>-wec-<round>-<session>` where session is e.g. fp1, fp2, fp3-lmgt3, fp3-hypercar, qual-lmgt3, qual-hypercar, hp-lmgt3, hp-hypercar, race
- intRound: integer round number for the season
- For WEC defaults, omit idLeague / strLeague / strSport / strSeason — the script applies them automatically

Output: ONLY the CSV text (header row + data rows). No commentary, no markdown code fences, no explanations, no trailing prose.

Schedule to convert:

<paste the weekend schedule here>
````

## Running the Script

The script lives at [`scripts/tsdb-update-events.sh`](../scripts/tsdb-update-events.sh) and authenticates via 1Password CLI.

### One-time setup

1. Store the TheSportsDB premium API key in 1Password (any vault, any item, any field name).
2. Note the `op://` reference, e.g. `op://Vault/Item/api_key`.

-

### Per-invocation

```bash
# Required: 1Password reference to the API key
export TSDB_APIKEY_OP_REF="p://Vault/Item/api_key"

# Always dry-run first to verify the parsed payload
./scripts/tsdb-update-events.sh --csv events.csv --dry-run

# Submit for real (3-second pause between calls by default)
./scripts/tsdb-update-events.sh --csv events.csv

# Custom rate (e.g. 5s for extra safety)
./scripts/tsdb-update-events.sh --csv events.csv --rate 5
```

### Default mode = dry-run

With no flag specified, the script prints the dry-run preview by default. This is the practical workflow given TSDB has no public write API:

```bash
# Just run it — defaults to dry-run, prints the per-row UI-labeled fields
./scripts/tsdb-update-events.sh --csv events.csv
# → "(no mode specified — defaulting to --dry-run; pass --lookup to resolve existing IDs instead)"

# Then paste each row's printed values into the TSDB webui edit page.
```

To explicitly suppress the hint line: `./scripts/tsdb-update-events.sh --csv events.csv --dry-run`.

### Override the WEC defaults (other leagues)

For a non-WEC league, set the defaults before invoking:

```bash
export TSDB_DEFAULT_IDLEAGUE=4370   # e.g. IMSA
export TSDB_DEFAULT_STRLEAGUE=IMSA
export TSDB_DEFAULT_STRSPORT=Motorsport
export TSDB_DEFAULT_STRSEASON=2026
export TSDB_DEFAULT_TZ="America/New_York"
./scripts/tsdb-update-events.sh --csv imsa-events.csv
```

Per-row `timezone`, `idLeague`, etc. in the CSV always win over the env-var defaults.

## Lookup Mode: Resolve Existing Event IDs

When a race weekend has already been added to TSDB and you want to *update* some fields (e.g. a session time was wrong), you need the existing `idEvent` values to put in the CSV's `idEvent` column. The `--lookup` mode queries TSDB for each row and writes a new CSV with `idEvent` populated on unique matches.

```bash
# 1. Lookup existing IDs (no POSTs; writes events.with-ids.csv)
./scripts/tsdb-update-events.sh --csv events.csv --lookup

# 2. Review the output — diff against events.csv to see what was matched
diff events.csv events.with-ids.csv

# 3. Edit fields you want to update in events.with-ids.csv (leave idEvent populated!)

# 4. Re-run for real — rows with idEvent set will edit; rows without will insert
./scripts/tsdb-update-events.sh --csv events.with-ids.csv
```

Output for each row is one of:

| Symbol | Meaning | Script action |
|---|---|---|
| `→ 2365955  ✓ matched` | One TSDB row matched exactly (season + round + filename) | Populates `idEvent` → will **edit** |
| `→ (no match — will be a new insert)` | TSDB has nothing matching | Leaves `idEvent` blank → will **insert** |
| `→ AMBIGUOUS (N matches: …)` | Multiple TSDB rows match (different rounds/seasons) | Leaves blank — manually disambiguate |
| `→ ERROR: …` | Network or API failure | Leaves blank; row is safe to re-run later |
| `→ keep existing idEvent=…` | `idEvent` already populated | Skips lookup |

### Lookup matching rules

For each row whose `idEvent` is blank, the script calls `searchevents.php?e={strEvent}&s={strSeason}` and filters results:

1. `strSeason` must match
2. `intRound` must match (if the CSV row has one)
3. `strFilename` must match (if the CSV row has one)

If exactly one TSDB row passes all filters → that's the match. Multiple → ambiguous. Zero → no match.

### Override output path

```bash
./scripts/tsdb-update-events.sh --csv events.csv --lookup --out events-resolved.csv
```

## Idempotency & Re-runs

- `idEvent` **blank** → on submit, TSDB **would** insert a new event row.
- `idEvent` **set** to an existing TSDB `idEvent` → on submit, TSDB **would** edit that row.
- Re-running with blank `idEvent` on a round that already exists would create **duplicates**.

Workflow for a new round (e.g. Barcelona round 9):

1. Leave `idEvent` blank in the CSV.
2. Run `--dry-run` to preview the values.
3. Enter the values manually in the TSDB webui (see "Manual entry via webui" below).

## TheSportsDB Has No Public Write API

Despite earlier expectations, TheSportsDB's public API (`api/v1/json/{key}/...`) is **read-only**. There is no `eventschedule_edit.php` or equivalent write endpoint — POSTs return HTTP 404. The forum confirms: writes happen only through the website's authenticated contribution UI, with role promotion required for editor access.

This is why the script:

- Refuses to run with no `--lookup` / `--dry-run` flag (default mode errors with exit 6)
- `--lookup` mode uses only read endpoints (`searchevents.php`) which DO work
- `--dry-run` mode generates copy-paste-ready values for manual entry

### Manual entry via webui (the only working submission path)

1. Generate your CSV (the doc + script help with this).
2. Run `--dry-run` to preview each event's fields, formatted with UI labels:

   ```text
   [1/9] 6 Hours of Barcelona Free Practice 1
     Date:                    2026-10-16
     Local Time HH-MM-SS:     11:30:00
     UTC Time HH-MM-SS:       09:30:00
     Event Name:              6 Hours of Barcelona Free Practice 1
     Venue:                   Circuit de Barcelona-Catalunya
     Country:                 Spain
     Season:                  2026
     Round:                   9
     …
   ```

3. Open <https://www.thesportsdb.com/> and navigate to the WEC league page.
4. Click **Add Event** (requires contributor role — apply via the [Apply to be an editor](https://www.thesportsdb.com/forum_topic.php?t=5726) thread if you don't have it).
5. For each row in the dry-run, fill in the form using the printed values.
6. Submit.

For bulk entry across many rows, consider building a Selenium/Playwright script that automates the webui form — the dry-run output is already in the right shape to drive it.
3. Optional: re-run with `idEvent` filled in (after looking them up via `eventsseason.php?id=4413&s=2026`) to edit.

## Rate Limits

TSDB enforces ([per the official forum](https://www.thesportsdb.com/forum_topic.php?t=5749)):

| Tier | Req/min | Req/sec hard cap |
|---|---|---|
| Free | 30 | 2 |
| Premium | 100 | 2 |
| Business | 120 | 2 |

Overage = HTTP 429 + 1-minute ban. The script's default `--rate 3` = 20 calls/min, safely under all tiers.

## TSDB API Reference

| Endpoint | Method | Auth |
|---|---|---|
| `https://www.thesportsdb.com/api/v1/json/{key}/eventschedule_edit.php` | POST (form-encoded) | HTTP Basic, API key as username |

Field reference for `eventschedule_edit.php`:
`idEvent`, `idLeague`, `strLeague`, `strSport`, `strSeason`, `intRound`, `strEvent`, `strFilename`, `strVenue`, `strCountry`, `dateEvent`, `strTime` (UTC), `strTimeLocal` (local), `strTimestamp` (epoch), `strHomeTeam`, `strAwayTeam`, `strResult`, `strPostponed`, `strLocked`.

Read endpoints (for verifying / looking up existing events):
- `eventsseason.php?id={idLeague}&s={strSeason}` — list all events in a season
- `lookupleague.php?id={idLeague}` — league metadata
- `lookupevent.php?id={idEvent}` — single event by id
- `searchevents.php?e={strEvent}&s={strSeason}` — search by event name
