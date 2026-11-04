# Papery standby

On Duo (iPhone19,4 / iOS 27.1), the main Papery tab enters standby after 3 seconds idle with `UIHinge.Status.partiallyOpen`. Opening flat or closing exits immediately. Opening a bookmark suppresses automatic re-entry until the next hinge-status change. There is no back button; unfolding or closing exits. DS, comics, keyboard entry, presented sheets, background scenes, and held touches cannot trigger entry. A passive window gesture recognizer resets the idle deadline without taking over list gestures.

The physical hinge axis, converted from the screen's fixed coordinate space, chooses side-by-side book panels or stacked tabletop panels. The cream canvas uses larger, medium-weight Papery monospace typography and darker text. Entry softly fades Papery away while the standby content settles into place; Reduce Motion disables the movement. The clock/date and battery stay in place; unread bookmarks shuffle without replacement every 30 seconds, pausing during interaction. Tapping a bookmark returns to Papery and opens its URL. Bookmarks appear as large, top-aligned page previews with a two-line title and smaller domain beneath the image. In book posture the preview fills the companion half’s width, without a heading above it. From 22:00 to 06:00, brightness is capped at 15% while active; prior brightness, battery monitoring, and idle-timer settings are restored on exit. The display stays awake only while standby is active.

Location is requested on first entry, used only while standby is active, and stopped in inactive scenes. Without access, weather/map use a clearly labeled central-SF fallback; no user dot or walking estimate is shown. Bike distances use a straight-line estimate with a 1.3 route allowance and 80 m/min walking pace; the UI labels time approximate. Pins select a bike/station, and the detail opens the feed's official Lyft rental URL (not a booking).

Data providers:
- Weather: https://open-meteo.com/en/docs — local conditions, highs/lows, wind, sunrise/sunset, and approximate 15-minute precipitation timing; refreshed every 15 minutes (retry every minute on error).
- Tides: https://api.tidesandcurrents.noaa.gov/api/prod/ — station 9414290 (San Francisco/Golden Gate), high/low predictions, feet relative to MLLW; GMT timestamps parsed explicitly. This is not an Ocean Beach-specific prediction. Shows the next future low, labeling tomorrow when applicable.
- Bikes: https://gbfs.lyft.com/gbfs/1.1/bay/gbfs.json — station information, station status, and free-bike status. Availability refreshed every minute; disabled/reserved bikes and non-renting stations excluded. The initial map frames nearby available bikes within 5 km. Pins then follow the visible map as you pan, with up to 120 markers; empty stations remain visible with zero counts. All bikes are shown by default, with an e-bike filter and recenter control. Counts older than five minutes are visibly stale. MapKit provides the native map and its attribution.

All polling tasks cancel with the standby view or inactive scene. No camera session is needed. No background location permission, new credentials, or provider API keys are used.

Validation:
```
swiftc Wooper/Standby/StandbyPolicy.swift tests/StandbyPolicyTests.swift -o /tmp/standby-policy-tests
/tmp/standby-policy-tests
swiftc Wooper/Standby/StandbyForecast.swift tests/StandbyForecastTests.swift -o /tmp/standby-forecast-tests
/tmp/standby-forecast-tests
```

The forecast test optionally accepts a directory with captured `standby-weather.json`, `bay-station_status.json`, `bay-station_information.json`, and `bay-free_bike_status.json` provider responses to check live schemas. The full app is built with the usual Wooper device scheme; real hinge behavior requires Duo hardware.

Spotify: the phone cannot read the local Spotify app's playback state without an authorized Spotify App Remote session. Standby instead uses the user's `https://neelr.dev/api/spotify` fallback, polling every 15 seconds only while active. A compact track/artist/device row with a slowly rotating vinyl record appears below the date only for playing responses and expires after 45 seconds without a successful response. Paused, empty, or failed responses hide it. Reduce Motion disables the spin; inactive scenes pause it. Tide and sunrise/sunset details use smaller 13-point text. Tapping opens the track; the app does not change playback. No Mac scripting is used by Flippy.

The one-second clock/bookmark task is tied to the standby view identity, not a Timer publisher re-created by parent updates. This prevents the main screen's idle ticks from continually restarting the bookmark countdown.
