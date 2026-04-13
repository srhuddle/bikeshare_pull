# CaBi Navigator

A GPS-guided audio navigation app for cycling multi-stop Capital Bikeshare routes. Designed for hands-free operation with mandatory station check-ins to prevent accidentally skipping stops.

## The Problem

Existing navigation apps (Google Maps, RideWithGPS) don't support the specific workflow needed for bikeshare station hopping:

- **Multi-stop routing** with audio is limited or clunky
- **No mandatory waypoints** - easy to bike past a station
- **Generic POI announcements** - "danger on your left" instead of station names
- **No re-routing after skip** - if you pass a station, you're stuck

## The Solution

A single-file web app that runs in your phone's browser with:

1. **Mandatory station confirmation** - Can't advance to next station without tapping "DOCKED"
2. **Audio announcements** - "In 50 meters, CaBi station on your left. Connecticut Ave & Macomb St"
3. **Live GPS tracking** - Real-time distance and direction to next station
4. **Passed station detection** - Warns if you bike past without docking
5. **Skip functionality** - Handle full/broken stations gracefully
6. **Progress tracking** - Always know where you are in the route

## How It Works

### Setup
1. Create your route as JSON (list of CaBi stations with coordinates)
2. Load the HTML file in your phone's browser
3. Paste route JSON and configure announce distance
4. Grant GPS permission and start

Demo included in this repo:
- `Dupont micro demo - 17th & P to Corcoran to 18th & New Hampshire`
- This is a short local test loop using current live station coordinates so you can verify GPS, audio, and station check-in behavior near home.
- `Day 05 demo - Franconia / Springfield (4 stations)`
- This preset is wired from the current route inventory and the TCX course points for that day so you can test station check-ins plus basic cue prompts without building your own JSON first.

### During Ride
- App tracks your position in real-time
- Displays distance and direction to next station
- Announces audio cue when you're within 50m (configurable)
- Shows big "DOCKED AT STATION" button
- After docking, tap button to advance to next station
- If you accidentally pass a station, audio warns you

### Station Confirmation Flow
```
Approaching → Audio announcement → Dock bike → Tap "DOCKED" → Next station loads
```

You **must** tap the button to advance. No way to accidentally skip a station.

## Technical Approach

### Core Technologies
- **Pure HTML/CSS/JS** - No build process, no dependencies
- **Geolocation API** - Phone's GPS with high accuracy mode
- **Web Speech Synthesis API** - Built-in text-to-speech (no API keys needed)
- **localStorage** (future) - Save/resume routes

### Key Algorithms

**Distance Calculation:**
- Haversine formula for lat/lng distance in meters
- Updates every second for live tracking

**Direction Detection:**
- Bearing calculation between user position and station
- 8-point compass conversion ("ahead and to your left", etc.)

**Passed Station Detection:**
- Tracks if distance is increasing after getting close
- Triggers audio warning if you bike past

**Audio Announcement Logic:**
```javascript
if (distance <= announceDistance && !hasAnnounced) {
    speak(`In ${distance} meters, CaBi station ${direction}. ${station.name}`);
    hasAnnounced = true;
}
```

### Why Single-File Web App?

**Pros:**
- No app store submission or updates
- Works on any phone with a browser
- Easy to modify and customize
- Can be hosted anywhere or run locally
- No installation required

**Cons:**
- Requires keeping phone screen on (use guided access mode)
- No background GPS (phone must be active)
- Manual route creation (for now)

## Route Data Format

Simple JSON array of stations:

```json
[
  {
    "name": "Connecticut Ave & Macomb St NW",
    "lat": 38.9282,
    "lng": -77.0521
  },
  {
    "name": "3000 Connecticut Ave NW",
    "lat": 38.9261,
    "lng": -77.0535
  },
  {
    "name": "Calvert St & Woodley Pl NW",
    "lat": 38.9213,
    "lng": -77.0520
  }
]
```

Get coordinates from:
- CaBi station map (inspect network requests)
- Google Maps (right-click → "What's here?")
- Your existing route planning tools

## Installation

### On Your Phone
1. Save `cabi-nav.html` to iCloud Drive/Dropbox
2. Open in Files app on iPhone
3. Tap to open in Safari
4. Grant location permission when prompted
5. (Optional) Add to Home Screen for app-like experience

### On Your Computer (for testing)
1. Open `cabi-nav.html` in Chrome/Firefox
2. Use "Developer Tools" to simulate GPS location
3. Test route logic before taking to the street

## Usage Tips

### Before Your Ride
- **Test your route** with 2-3 stations first
- **Check GPS accuracy** - Needs ~5-10m precision
- **Adjust announce distance** based on your riding speed
- **Enable "Do Not Disturb"** to prevent notification interruptions
- **Keep phone charged** - GPS drains battery

### During Your Ride
- **Mount phone on handlebars** (optional, but helpful)
- **Use earbuds** - AirPods work great for audio
- **Glance at distance** as you approach stations
- **Tap "DOCKED" immediately** after docking (don't forget!)
- **Use "Skip"** if station is full/broken

### Safety
- This is **audio-first** by design - don't stare at your phone
- The big distance number is for quick glances only
- Audio cues tell you everything you need to know
- If in doubt, stop and check the screen

## Customization Ideas

### Easy Tweaks (Edit the HTML)
- **Announce distance:** Change `announceDistance` default (line 318)
- **Audio rate/pitch:** Modify `utterance.rate` (line 234)
- **Color scheme:** Edit CSS variables at top (lines 12-22)
- **Distance units:** Change from meters to feet

### Future Enhancements (Needs Coding)
- **Turn-by-turn routing** - Add Google Directions API calls
- **Visual map** - Integrate Mapbox/Leaflet
- **Route import** - Load GPX/KML files
- **Offline support** - Service worker for caching
- **Stats tracking** - Time per station, total distance
- **Route sharing** - Generate shareable URLs
- **Auto-advance** - Use geofencing to auto-confirm docking

## Architecture

```
User Position (GPS)
    ↓
Distance Calculation (Haversine)
    ↓
Direction Calculation (Bearing)
    ↓
Audio Triggers (50m threshold)
    ↓
UI Updates (1Hz refresh)
    ↓
Manual Confirmation Required
    ↓
Advance to Next Station
```

### State Management
```javascript
{
  route: [],                    // Array of station objects
  currentStationIndex: 0,       // Which station we're heading to
  completedStations: 0,         // How many we've docked at
  userPosition: {lat, lng},     // Current GPS position
  hasAnnounced: false,          // Prevents repeat announcements
  lastDistance: Infinity        // For passed-station detection
}
```

## Troubleshooting

**GPS not working:**
- Check browser location permission (Settings → Safari → Location)
- Ensure you're not in airplane mode
- Try reloading the page

**No audio announcements:**
- Check phone is not on silent
- Test by typing in console: `window.speechSynthesis.speak(new SpeechSynthesisUtterance('test'))`
- Some browsers require user interaction before speech works

**Distance seems wrong:**
- Haversine formula assumes spherical Earth (good enough for <100km)
- GPS accuracy varies (buildings, tunnels affect signal)
- Wait 5-10 seconds after loading for GPS to stabilize

**Audio cut off mid-sentence:**
- Reduce speech rate: `utterance.rate = 0.9`
- Shorten station names in your route JSON

## Development Workflow

This app is designed for **vibe-coding** with Claude/Codex:

1. **Test locally** in browser dev tools
2. **Modify HTML** directly (single file = easy)
3. **Test on phone** via AirDrop/iCloud
4. **Iterate quickly** - no build process

### Recommended Dev Setup
- VS Code with Live Server extension
- Chrome DevTools for GPS simulation
- Test data: 2-3 nearby CaBi stations

## Performance Considerations

- **GPS updates:** 1Hz is plenty (more = battery drain)
- **Distance calculations:** Haversine is fast (<1ms)
- **Speech synthesis:** Async, doesn't block UI
- **Battery impact:** GPS is the main drain (~5-10% per hour)

## Privacy & Data

- **No server communication** - Everything runs locally
- **No tracking** - GPS data never leaves your phone
- **No analytics** - Pure client-side code
- **No accounts** - No login required

## License

Do whatever you want with it. Built for personal use.

## Credits

Created to solve the "bikeshare station hopping with audio nav" problem that existing apps don't address.

Built with vanilla JavaScript because sometimes you don't need a framework.
