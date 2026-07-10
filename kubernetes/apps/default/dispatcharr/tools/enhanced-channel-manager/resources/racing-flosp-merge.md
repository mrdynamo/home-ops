# FloSports ECM Merge for DIRTVision/FloRacing

```yaml
- name: 'DIRTVISION + FLORACING: FLO SPORTS stream merge'
  description: "Mirror of rule id=24 (PPV/LIVE EVENT merge) but for FLOSPORTs streams.\
    \ Catches streams named \"(FLSP NNN) | flo*: YYYY <event> at <venue> (<short name>)\
    \ (date)\" \u2014 extracts the parenthesized short name (which maps to the FLORACING\
    \ channel name) and merges into the existing channel of that name in FLORACING\
    \ (912) or DIRTVISION (913). For example, \"(FLSP 815) | floracing: 2026 Weekly\
    \ Racing at Utica_Rome Speedway (Weekly Racing at Utica_Rome)\" routes to the\
    \ channel \"Weekly Racing at Utica Rome\"."
  enabled: true
  priority: 4
  m3u_account_id: null
  m3u_account_name: null
  target_group_id: null
  target_group_name: null
  conditions:
  - case_sensitive: false
    type: stream_name_matches
    value: '^\(FLSP \d+\) \| flo[a-z]+: \d{4} .+ \(([^()]+)\) \(\d{4}-\d{2}-\d{2}'
  actions:
  - pattern: '^\(FLSP \d+\) \| flo[a-z]+: \d{4} .+ \(([^()]+)\) \(\d{4}-\d{2}-\d{2}.*$'
    replacement: \1
    source_field: stream_name
    type: set_variable
    variable_mode: regex_replace
    variable_name: venue_name
  - find_channel_by: name_exact
    find_channel_value: '{var:venue_name}'
    max_streams: 5
    target: existing_channel
    target_channel_in_group:
    - 912
    - 913
    type: merge_streams
  run_on_refresh: true
  stop_on_first_match: false
  sort_field: null
  sort_order: asc
  sort_regex: null
  stream_sort_field: smart_sort
  stream_sort_order: asc
  quality_tie_break_order: desc
  quality_m3u_tie_break_enabled: true
  normalization_group_ids: []
  skip_struck_streams: false
  probe_on_sort: false
  orphan_action: keep
  match_scope_target_group: true
  match_scope_group_id: null
  allow_manual_channel_merge: false
```
