# Backlog

## RWGPS / TCX Cue Tweaks

- [ ] Investigate inconsistent RWGPS display of kickoff Metro cue versus starting `CaBi station:` cue.
  - Current state:
    - intermediate and final `CaBi station: ...` cues are working
    - starting `CaBi station:` cue is working in at least some routes
    - kickoff Metro cue display is inconsistent across routes
    - RWGPS still tends to place the starting `CaBi station:` cue above the Metro kickoff cue in the cuesheet, even when the file encodes the opposite distance ordering
  - Desired behavior:
    - preserve the `CaBi station:` cue as the primary requirement
    - if possible, also show a distinct `Start from <Metro> Metro Station` kickoff cue without RWGPS suppressing it
    - ideal ordering:
      1. `Start from <Metro> Metro Station`
      2. `CaBi station: <starting dock>`
  - Priority:
    - low
  - Reason:
    - current exports are already usable because the station cue is visible
    - remaining issue is a Ride with GPS display quirk, not a blocker for navigation
