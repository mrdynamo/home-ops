# PPV/LIVE ECM Merge for DIRTVision/FloRacing

```yaml
- name: 'DIRTVISION + FLORACING: PPV/LIVE EVENT stream merge'
  description: 'Generic merge for DIRTVISION PPV EVENT streams. Uses non-capturing
    group (?:) for the event prefix so group 1 captures the venue name. Supports LIVE
    EVENT (with - separator), PPV EVENT (with : separator), US/UK PPV EVENT variants.
    Merges into the existing channel whose name matches the extracted venue.'
  enabled: true
  priority: 3
  m3u_account_id: null
  m3u_account_name: null
  target_group_id: null
  target_group_name: null
  conditions:
  - case_sensitive: false
    type: stream_name_matches
    value: ^(?:LIVE EVENT|PPV EVENT|US PPV EVENT|UK PPV EVENT) \d+[:\- ]+(.+) \(\d+\.\d
  actions:
  - pattern: ^(?:LIVE EVENT|PPV EVENT|US PPV EVENT|UK PPV EVENT) \d+[:\- ]+(.+) \(\d+\.\d.*$
    source_field: stream_name
    type: set_variable
    variable_mode: regex_extract
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
  stop_on_first_match: true
  sort_field: null
  sort_order: asc
  sort_regex: null
  stream_sort_field: smart_sort
  stream_sort_order: asc
  quality_tie_break_order: desc
  quality_m3u_tie_break_enabled: true
  normalization_group_ids:
  - 1
  - 2
  - 3
  - 4
  - 5
  - 6
  - 7
  - 8
  skip_struck_streams: false
  probe_on_sort: false
  orphan_action: delete
  match_scope_target_group: true
  match_scope_group_id: null
  allow_manual_channel_merge: false
```
