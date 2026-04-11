# Fairfax Bikeshare Proposal References

This document tracks the source lineage for the Fairfax proposal overlay datasets used by `cabi_visit_map_app.R`.

The datasets are intentionally kept separate:
- `data/fairfax_i66_proposed_stations_2026_04.csv`
- `data/fairfax_older_unbuilt_proposals_2026_04.csv`

## Dataset: `fairfax_i66_proposed_stations_2026_04.csv`

Purpose:
- Fairfax County's April 2026 I-66 corridor proposal set.
- Used for the `Overlay proposed Fairfax I-66 stations` map layer.

Primary sources:
- Fairfax County presentation PDF:
  - `https://www.fairfaxcounty.gov/transportation/sites/transportation/files/Assets/Documents/PDF/bikeprogram/capital%20bike%20share/NVTC%2066%20Parallel%20Trail%20Expansion.pdf`
- Fairfax County PublicInput page:
  - `https://publicinput.com/cabi-66corridor`
- PublicInput map data endpoint used to recover live map assets:
  - `https://publicinput.com/Comments/GetMapComments?pollId=380952`

Stored source artifacts:
- Local temporary research pull used during ingestion:
  - `/tmp/NVTC_66_Parallel_Trail_Expansion.pdf`
- PublicInput KMZ files referenced by `GetMapComments` response:
  - `https://PublicInput.com/Customer/DownloadMapfile/EAeTjL.kmz`
  - `https://PublicInput.com/Customer/DownloadMapfile/64tNFW.kmz`

Method:
- Site names were confirmed from the Fairfax presentation.
- Point coordinates were taken from the PublicInput KMZ placemarks rather than hand geocoded.

Notes:
- This dataset reflects the 14-site I-66 proposal map.
- A few labels differ slightly between the presentation, the PublicInput map, and local news coverage.
- The CSV preserves the map label in `station_name` and, where needed, the presentation wording in `presentation_name`.

## Dataset: `fairfax_older_unbuilt_proposals_2026_04.csv`

Purpose:
- Older Fairfax expansion proposals outside the I-66 April 2026 set.
- Used for the `Overlay older Fairfax proposals not yet built` map layer.

This dataset currently includes:
- Annandale / Bailey's Crossroads / Seven Corners / Braddock proposals from the Aug. 2024 Mason-Braddock planning materials.
- Remaining unbuilt Mount Vernon proposals from the Jan. 2024 Mount Vernon planning materials.

### Mason / Braddock source set

Primary sources:
- Fairfax County transportation news:
  - `https://www.fairfaxcounty.gov/transportation/news/T14_24`
- Fairfax County presentation PDF:
  - `https://www.fairfaxcounty.gov/transportation/sites/transportation/files/Assets/Documents/PDF/bikeprogram/capital%20bike%20share/Mason-Braddock-Bikeshare-PIM_8-22-24%20Web.pdf`
- Fairfax County PublicInput page:
  - `https://engage.fairfaxcounty.gov/r2887`
- FFXnow summary article:
  - `https://www.ffxnow.com/2024/08/20/annandale-baileys-crossroads-eyed-for-next-capital-bikeshare-expansion/`

Method:
- Site names were taken from Fairfax County materials.
- The PublicInput page exposes per-site images and titles, but not a single map/KMZ layer comparable to the I-66 page.
- Coordinates were approximated via ArcGIS geocoding from the published intersection/site names.

### Mount Vernon source set

Primary sources:
- Fairfax County transportation news:
  - `https://www.fairfaxcounty.gov/transportation/news/T1_24`
- Fairfax County presentation PDF:
  - `https://www.fairfaxcounty.gov/transportation/sites/transportation/files/Assets/Documents/PDF/bikeprogram/capital%20bike%20share/Mount-Vernon-District_1-18-24.pdf`
- Fairfax County PublicInput page:
  - `https://engage.fairfaxcounty.gov/v6127`
- Fairfax County current bikeshare page:
  - `https://www.fairfaxcounty.gov/transportation/bike-walk/fairfax-county-bikeshare`
- Friends of the Mount Vernon Trail summary:
  - `https://mountvernontrail.org/2024/01/13/support-capital-bikeshare-expansion-on-the-mvt-in-fairfax-county-by-commenting-by-february-2/`

Method:
- Site names were taken from Fairfax County materials.
- Fairfax County's current bikeshare page was used to exclude locations listed as already completed.
- Coordinates were approximated via ArcGIS geocoding from the published intersection/site names.

Completed locations intentionally excluded from this dataset:
- `Huntington Ave & Metroview Pkwy`
- `Huntington Ave & Farrington Ave`
- `Huntington Ave & Old Richmond Hwy`
- `Huntington Metro North`

Why excluded:
- Fairfax County's current bikeshare page states these were completed in August 2025.
- The current live CaBi GBFS inventory also includes the three Huntington Avenue sites and `Huntington Metro North`.

## Geocoding notes

The older-proposals dataset is less exact than the I-66 dataset.

Precision tiers:
- High confidence:
  - explicit street intersections
- Medium confidence:
  - named station entrances or named facilities geocoded to a nearby point
- Lower confidence:
  - park/trail proposals where the published source did not provide exact dock coordinates

Examples of approximate points:
- `Americana Dr & Americana Pl`
- `Huntington Metro South`
- `Mt Vernon Trail & Belle Haven Park`
- `Mt Vernon Trail & Riverside Park`
- `Mt Vernon Trail & Mount Vernon Estate`
- `Fort Hunt Park`

If Fairfax later publishes exact maps or KMZ layers for these older proposal groups, prefer replacing those geocoded points with official coordinates.
