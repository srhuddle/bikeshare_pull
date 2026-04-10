# Turn-By-Turn Options

## Goal

The project already produces a strong station coverage plan:
- assign all CaBi stations to ride days
- optimize stop order within each day
- estimate commute + bike time with OSRM-aware routing

The remaining usability goal is different:
- produce turn-by-turn navigation that is practical to use while riding
- minimize the need to stare at a map for the next station
- keep the process rerunnable as CaBi adds new stations

The desired end state is:
- rerun the planner
- get updated route geometry
- get usable navigation artifacts with little or no manual cleanup

## Current Planner State

The planner now does these things reasonably well:
- day assignment
- within-day stop ordering
- GPX export per day
- dense street/path geometry export using OSRM

Current canonical outputs:
- [`outputs/route_plan`](/Users/scotthuddle/Documents/Bikeshare%20Pull/outputs/route_plan)
- [`outputs/route_plan_gpx`](/Users/scotthuddle/Documents/Bikeshare%20Pull/outputs/route_plan_gpx)

External cuesheet generation now also exists:
- [`scripts/export_route_plan_cues.R`](/Users/scotthuddle/Documents/Bikeshare%20Pull/scripts/export_route_plan_cues.R)
- example outputs for Reston in [`outputs/route_plan_cues`](/Users/scotthuddle/Documents/Bikeshare%20Pull/outputs/route_plan_cues)

## Approach So Far

### 1. Export GPX from the optimized plan

Initial approach:
- export one GPX per day from the planner
- upload those GPX files into Ride with GPS
- let RWGPS generate navigation

What changed over time:
- first GPX exports only had sparse route points
- later GPX exports added:
  - waypoints for all CaBi stations
  - route points for stop order
  - dense OSRM track geometry between consecutive stops
- later still, exact station coordinates were inserted into the track so docks are on or near the exported line

This improved import fidelity a lot.

### 2. Try to use Ride with GPS as the navigation layer

We tested RWGPS because:
- the user has used it before
- it supports route imports
- it supports turn-by-turn voice navigation

What we learned:
- RWGPS imports both the sparse route and the dense track as separate routes
- the dense `Street Route` import is visually much better than the sparse import
- RWGPS does not automatically create a cuesheet for the imported route
- the web Route Planner does not provide a reliable, automation-friendly way to convert the imported route into a cue-generating planner route

### 3. Generate cues externally from OSRM

We added an external cuesheet path:
- call OSRM `/route` with `steps=true`
- parse maneuver instructions
- write:
  - cuesheet CSV
  - plain text turn list

That now works for Reston:
- [`outputs/route_plan_cues/day_02_wiehle_reston_metro_north_cuesheet.csv`](/Users/scotthuddle/Documents/Bikeshare%20Pull/outputs/route_plan_cues/day_02_wiehle_reston_metro_north_cuesheet.csv)
- [`outputs/route_plan_cues/day_02_wiehle_reston_metro_north_turns.txt`](/Users/scotthuddle/Documents/Bikeshare%20Pull/outputs/route_plan_cues/day_02_wiehle_reston_metro_north_turns.txt)

This proves the repo can generate turn instructions itself.

## What Has Worked

### Worked: dense GPX export

The current GPX export is much better than the original version.

It now gives:
- realistic street/path geometry
- visible station waypoints
- route shape that generally matches the optimized day

This is useful for:
- reviewing route quality
- uploading to external cycling tools
- checking whether a day is plausible on the ground

### Worked: external cuesheet generation

The project can now generate step-by-step instructions directly from OSRM.

This is important because:
- it removes dependence on RWGPS inventing turns
- it makes turn-by-turn a first-class output of the repo

### Worked: identifying the actual system boundary

The work clarified that there are three separate problems:
1. day assignment
2. stop ordering
3. navigation artifact generation

The planner is now fairly good at 1 and 2.
The remaining weakness is mostly 3.

## What Has Not Worked

### Not worked: using RWGPS web editing as the main automation path

We tried to make RWGPS generate a cuesheet from the imported route through the web editor.

What failed:
- imported routes appear in the editor
- `Trace` and related controls are visible
- but the imported route is not exposed as a selectable planner segment in a reliable way
- automation could not activate `Trace` on the imported route
- manual editing is brittle and easy to break

Conclusion:
- RWGPS web editing is not a dependable automation target for this project

### Not worked: uploading an external cuesheet into RWGPS

RWGPS does not provide a clean path to:
- upload GPX from the repo
- upload a separate cuesheet CSV/TXT
- merge those into spoken turn-by-turn navigation

Conclusion:
- external cuesheet files are useful repo outputs
- they are not directly consumable by RWGPS in an automated way

### Not worked: assuming payment solves the problem

RWGPS offers voice navigation in the mobile app, but:
- that does not prove the imported route will produce good cues
- the web editor still does not provide a clean automation path

Conclusion:
- a free-trial mobile test is still reasonable
- but payment should not be treated as evidence the import workflow is solved

## Current Best Interpretation

The project is now in this state:

- route planning itself is in decent shape
- exported route geometry is good enough to inspect and likely ride
- external cues can be generated from OSRM
- Ride with GPS is useful as a viewer and possibly as a mobile navigation consumer
- Ride with GPS is not a strong automation endpoint for building cuesheets from imported routes

## Best Options Going Forward

### Option 1: Keep RWGPS as a viewer / possible phone navigator

Use RWGPS for:
- importing the dense `Street Route` GPX
- viewing the route on the phone
- optionally testing mobile `Navigate` during the trial

Do not rely on RWGPS for:
- web-based cue generation automation
- route reconstruction from imported geometry

### Option 2: Make navigation a repo-native output

This is the strongest technical direction.

Build and maintain:
- GPX route export
- cuesheet CSV
- turn list TXT
- stop sheet CSV/TXT

Potential next export formats:
- TCX with course points
- other course-point/navigation formats for bike computers or compatible apps

This direction is consistent with the project goal:
- rerunnable
- low manual cleanup
- less dependence on a third-party planner UI

### Option 3: Change the downstream navigation target

If RWGPS mobile navigation does not behave well enough, test a more navigation-first target:
- Garmin ecosystem
- Wahoo ecosystem
- Komoot

These may be better final consumers for exported route geometry + cues than RWGPS.

## Recommended Next Step

The most practical next move is:
- keep generating dense GPX and external cues from the repo
- package those outputs cleanly for a single day
- test one downstream navigation target end-to-end

The best first test day is still:
- Reston

That day now has:
- a reasonable dense GPX route
- a generated cuesheet
- a generated turn list

## Bottom Line

Turn-by-turn is still a gap, but the gap is narrower and better understood now.

What is solved:
- route planning
- dense route export
- external turn generation

What is not solved:
- seamless ingestion of those turns into Ride with GPS web tooling

The repo should move toward producing navigation artifacts directly, instead of depending on RWGPS to reconstruct them after import.
