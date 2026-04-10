# Project Findings: CaBi Station Completion Optimizer

## 1. Executive Summary
The current system successfully plans a 28-day route to visit 820 Capital Bikeshare stations. However, the reliance on Euclidean (straight-line) clustering and manual boundary "hacks" limits its efficiency. To achieve the 30-day goal with minimal friction, the system should transition to OSRM-native clustering, elevation-aware routing, and automated turn-by-turn GPX generation.

## 2. Current Architecture Review
*   **Methodology:** Cluster-First (K-Means), Route-Second (Nearest Neighbor + 2-Opt TSP).
*   **Baseline Stats:** 820 stations, 28 planned days, ~721 km (448 mi), ~80 total hours.
*   **Strengths:** Sophisticated "Last Mile" Metro-proximity scoring; robust post-cluster repair logic.
*   **Weaknesses:** 
    *   Initial clustering ignores physical barriers (rivers, highways) not explicitly penalized.
    *   Manual boundary fixes in `cabi_route_planner.R` indicate the model isn't capturing real-world constraints naturally.
    *   GPX output lacks navigation metadata (cue sheets), requiring manual cleanup in external apps.

## 3. Pathing & Efficiency Optimization
### A. From Euclidean to Routing-Centric Clustering
*   **The Issue:** K-Means uses straight-line distance, which clusters stations together that might be separated by a river or highway.
*   **Recommendation:** Pre-calculate a full OSRM distance matrix for all 800+ stations. Use **K-Medoids** or **Spectral Clustering** on the actual "bike time" matrix. This removes the need for manual boundary "hacks."

### B. Global Vehicle Routing (VRP)
*   **The Issue:** Each day is solved as an independent TSP.
*   **Recommendation:** Use a **Multi-Depot VRP solver** (e.g., Google OR-Tools). This allows the optimizer to "trade" stations between days to minimize total monthly travel time, rather than just daily route length.

## 4. Navigation & Turn-by-Turn Directions
### A. OSRM Instructions Integration
*   **Current State:** `export_route_plan_gpx.R` fetches coordinates but ignores routing steps.
*   **Recommendation:** Modify the OSRM request to include `steps=true`. Parse the `maneuver` and `name` fields to generate a "Cue Sheet" directly in the GPX `<rtept>` or `<coursepoint>` extensions. This provides native turn-by-turn prompts on Garmin/Wahoo/RideWithGPS devices.

### B. Elevation & Bike Path Prioritization
*   **Elevation:** Integrate a Digital Elevation Model (DEM) into the OSRM backend. Adjust the `bicycle.lua` profile to apply a high penalty to uphill segments, forcing the planner to find flatter routes even if they are slightly longer.
*   **Safety:** Increase the "weight" of OpenStreetMap tags for dedicated bike lanes (`cycleway=track`) and reduce the weight for high-traffic arterials.

## 5. Strategic Recommendations
*   **The "Stay-Out" Strategy:** For remote clusters (e.g., Reston, Herndon, Gaithersburg), the 2-hour daily round-trip commute from Dupont Circle is the single largest efficiency drain. 
    *   *Optimization:* Identify "Distant Hubs" and plan them as 2-day back-to-back blocks with a local overnight stay.
*   **Metro-as-a-Link:** Currently, Metro is used to start/end days. 
    *   *Optimization:* Allow the routing solver to "hop" on Metro mid-day if the transit time between two station clusters is <50% of the biking time (e.g., crossing from Silver Spring to Bethesda).

## 6. Implementation Roadmap (30-Day Goal)
1.  **Week 1:** DC Core/High-Density (40+ stations/day). Leverage short inter-dock distances.
2.  **Week 2:** Metro-Corridor Sprints. Use Red/Orange/Silver lines to reach dense suburban pockets.
3.  **Week 3:** Remote Pockets. Use the "Distant Hub" strategy for Reston/Herndon.
4.  **Week 4:** Cleanup. Use the Shiny app to identify any "orphaned" stations missed due to dock availability or maintenance.
