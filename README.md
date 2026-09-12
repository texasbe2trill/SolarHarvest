# ☀️ Solar Harvest

**A Connect IQ data field that finally tells you what your solar watch is actually doing with all that sunlight.**

![Solar Harvest hero](docs/hero-1440x720.png)

Garmin put a solar panel on your watch. It shows you a tiny sun icon and calls it a day. Solar Harvest rips that icon off and replaces it with an entire measurement instrument: real drain and gain rates measured from your own battery (not a marketing constant), a live sun compass that tracks the sky, a battery icon that actually animates, and enough honest, well tested data science to make you feel like your watch has a PhD in astrophysics.

It is free. It always will be. See [Supporting this project](#supporting-this-project) if you want to say thanks anyway.

## Table of contents

- [Why this exists](#why-this-exists)
- [The seven pages](#the-seven-pages)
- [What makes it actually good](#what-makes-it-actually-good)
- [Alerts](#alerts)
- [Supported devices](#supported-devices)
- [Getting it on your watch](#getting-it-on-your-watch)
- [Building it yourself](#building-it-yourself)
- [How it is put together](#how-it-is-put-together)
- [Testing, and why there is so much of it](#testing-and-why-there-is-so-much-of-it)
- [Known limits](#known-limits)
- [Contributing](#contributing)
- [License](#license)
- [Supporting this project](#supporting-this-project)

## Why this exists

Every solar Garmin ships with the same quiet lie baked into its default watch face: a little sun glyph that is either lit or it is not. It never tells you how much sun, whether the canopy overhead is actually blocking it, or whether the last hour genuinely bought you extra battery or you just got lucky with the weather.

Solar Harvest was built to answer the question a solar watch should have been answering the whole time: **is the sun actually helping right now, and by how much?**

Every number this field shows is either raw physics (the sun's real position, computed from the NOAA solar equations, not a weather API that goes stale the moment your phone stops syncing) or something measured live off your own watch's own battery, on this activity, on this device. Nothing is a guessed constant dressed up as a fact.

## The seven pages

Cycle through them automatically, pin your favorite, or map the lap button to flip pages on demand (see [Lap button behavior](#lap-button-behavior)).

![All seven pages](docs/pages-51mm.png)

| Page | What it tells you |
| --- | --- |
| **Solar Now** | Live intensity, a scrolling bar chart of the last several minutes, and today's average and peak |
| **Full Sun Time** | Cumulative minutes spent at full solar charge, plus the running bonus that time bought your battery |
| **Battery** | An animated battery icon (not a chart) that fills and flows in the direction your level is actually moving, with the measured drain or gain rate beside it |
| **Sun Window** | Minutes of full sun still ahead before sunset, or a live daylight arc showing where you are in the day |
| **Catching** | The signature metric: what share of the sunlight your position and the sun's height *should* be delivering are you actually catching. Low despite a high sun means shade, canopy, or a sleeve, not a broken sensor |
| **Sun Bonus** | The hour's drain, split into what the sun paid for and what your battery paid for, fitted from real regression against your own measured data (and marked with a `~` the moment it is leaning on a value learned from an earlier activity instead of this one) |
| **Compass** | Where the sun actually is right now, plus its whole path across today's sky, dotted ahead of your current position like a weather radar loop |

An animated preview, captured straight from the simulator:

![Cycling through every page](docs/solar-harvest.gif)

## What makes it actually good

A few of the decisions under the hood, for anyone who likes reading source code as much as I do:

- **Real solar geometry, not a weather cache.** Sunrise, sunset, elevation, and azimuth all come from the NOAA solar position equations, computed on-device from your GPS fix and the date. `Weather.getSunset()` returns whatever your phone last synced, which on a watch that has not paired all day is simply `null`. Geometry does not have that problem.
- **Battery numbers are measured, never assumed.** The drain and gain rates you see are fitted from edge-to-edge transitions in your own battery's own reporting, debounced against the sensor's natural dither. A number this project cannot measure yet, it does not show, and a dash is a better answer than a lie.
- **The "sun bonus" is a real regression, not a fixed ratio.** How much runtime the sun bought you this hour is fitted against your own measured drain across changing light conditions, the same way you would if you plotted it by hand. Values it has not measured yet on this activity fall back to whatever an earlier activity taught it (Garmin's `Application.Storage` persists it between runs), always marked with a `~` so you can tell a live number from a remembered one.
- **Every developer field actually shows up on Garmin Connect.** Getting a `FitContributor` field into the raw `.FIT` file is the easy half. Connect's charts and activity summary need a second resource, `fitContributions.xml`, mapping each field to a chart title, a unit, and a color, keyed purely by numeric id. Skip it and your data records perfectly and Connect shows nothing at all. Fourteen fields make that trip correctly here.
- **Two device generations, one codebase.** The fēnix 7 line runs an older Connect IQ API than everything released after it, missing a callback (`onTimerLap2`) that everything newer gets. Rather than dropping those watches, the build compiles that one code path out per device tier and falls back to the older callback where needed, so the whole fēnix 7 through fēnix 9 lineup ships from the same source.
- **The compass ring is a real animation of time, not a snapshot.** Half of it is solid (where the sun has already been), and a dotted arc sweeps ahead of it (where it is still going before sunset), the same visual language a weather radar loop uses for "already happened" versus "about to happen."

### Lap button behavior

Pressing the physical lap button always records a lap. A data field has no way to prevent that, whether or not Solar Harvest is even installed. The optional "lap button changes page" setting rides along on that same unavoidable button press to flip pages too, but only for an actual manual press, never for an automatic lap the watch triggers itself by distance, time, or a workout step. Turn it on and pace intervals with auto-lap enabled without your data field silently flipping pages under you every mile.

## Alerts

Four `DataFieldAlert` cards, tuned to say something only when it is actually worth interrupting you for:

- **Battery gain**: the sun has started outrunning your drain
- **In shade**: a sustained drop in light, not a passing cloud shadow
- **Back in sun**: recovery after a shade alert
- **Sunset warning**: full sun is about to run out for the day

Each one is built to refuse far more often than it fires: minutes-long holds before triggering, a dead band between thresholds so it cannot flap, and a refractory window so the same condition cannot re-alert every second it stays true.

## Supported devices

One `manifest.xml` entry is often several retail names sharing identical hardware underneath (a fēnix 7X is also sold as a tactix 7, a quatix 7X Solar, and an Enduro 2, for instance), so the real compatibility list runs longer than the 14 build targets suggest:

fēnix 7 · fēnix 7 Pro · fēnix 7 Pro Solar (No Wi-Fi) · fēnix 7S · fēnix 7S Pro · fēnix 7X · fēnix 7X Pro · fēnix 7X Pro (No Wi-Fi) · fēnix 8 Solar (47mm / 51mm) · fēnix 9 Pro Solar (47mm / 51mm) · Enduro 2 · Enduro 3 · tactix 7 · tactix 8 Solar (51mm) · quatix 7 · quatix 7X Solar · Forerunner 955 Dual Power

That spans two Connect IQ API generations and three physical screen sizes (240px, 260px, and 280px, all round), and the layout is verified against real simulator captures at every size, not just the one watch this was built on.

## Getting it on your watch

Once it is listed, the easiest path will be the Connect IQ Store on your phone or at [apps.garmin.com](https://apps.garmin.com). Until then, or if you would rather build from source, see below.

## Building it yourself

You will need:

- The [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) (built and tested against 9.2.0)
- A Connect IQ developer key (`monkeyc --help` under `-y`, or generate one with the SDK's key tool)
- Garmin's Connect IQ VS Code extension, or the SDK's command line tools directly

```bash
# Build for the simulator
monkeyc -d fenix9prosolar51mm -f monkey.jungle -o bin/SolarHarvest.prg -y developer_key

# Build a distributable package for every supported device at once
monkeyc -e -f monkey.jungle -o dist/SolarHarvest.iq -y developer_key -r

# Run the unit test suite
monkeyc -d fenix9prosolar51mm -f monkey.jungle -o bin/test.prg -y developer_key --unit-test
monkeydo bin/test.prg fenix9prosolar51mm -t
```

The `tools/` directory has the scripts used to generate every screenshot and the GIF in this README, straight from the simulator. They need `CIQ_SDK_BIN` pointed at your SDK's `bin/` directory and Python's `pyobjc-framework-Quartz` for window capture (macOS only). `tools/check_fit.py` is worth knowing about too: point it at a `.FIT` file pulled off your watch and it tells you exactly which developer fields made it in and whether Connect has any chance of rendering them, which will save you the multi-hour detour it took to learn this app needs `fitContributions.xml` at all.

## How it is put together

```
source/
  SolarPowerView.mc     the field itself: seven pages, rendering, settings, alerts wiring
  SolarModel.mc         solar intensity tracking, smoothing, trend, zones
  BatteryModel.mc       edge-to-edge drain/gain measurement, regression, projections
  SolarGeometry.mc      NOAA solar position equations (elevation, azimuth, sunrise/sunset)
  SolarAlerts.mc        alert condition logic
  SolarAlertView.mc     the full-screen alert card
  FitRecorder.mc        the fourteen developer FIT fields
  LayoutPlanner.mc      vertical layout math shared by every page
  SafeArea.mc           keeps content clear of a round bezel and any obscuring UI
  Palette.mc            the color system, tuned for a reflective MIP display
  SunWindow.mc          shared daylight-window state
  SolarPowerApp.mc      the Connect IQ application entry point

resources/
  fitContributions/     tells Garmin Connect how to chart the FIT fields above
  settings/, strings/   user-facing settings and every string, ready for translation

tools/                  screenshot, GIF, and FIT-inspection tooling used to build docs/
docs/                   the images and GIF in this README
```

## Testing, and why there is so much of it

83 unit tests on the newer device tier, 80 on the fēnix 7 generation (three exercise a callback that tier does not have). They run against every layout size the field ships to, not just one, and a stress section deliberately hammers the field with a dense sweep of times of day, extreme battery states, adversarial multi-day alert sequences, and a long-activity soak test checking for integer accumulators that would otherwise overflow on an ultra-length ride.

A few things worth knowing if you are reading the test file:

- `FitContributor.Field` cannot be constructed at all outside a live, watch-recorded activity. It throws a native error that bypasses Monkey C's own exception handling entirely, so `FitRecorder` itself is untestable by design, and every test that builds a view sets `gSkipFitRecording` first. What *is* tested is every piece of arithmetic that feeds it.
- The Connect IQ simulator has its own sharp edges: a crashed run leaves it pinned on a crash screen that then poisons every later screenshot, and a simulator that has been running a while can report frame costs several times higher than a fresh one. `tools/preview.sh` restarts the simulator before every single capture because of the first one.

## Known limits

Being upfront about what this project cannot do, because a features list with no edges is not a features list you should trust:

- **No real device battery-life (mAh) measurement.** Everything here is measured in percentage points per hour off the OS's own reporting, which is the only battery signal a Connect IQ data field is given. It cannot see the actual chemistry.
- **A brand new watch has to learn your solar bonus before it can show one.** The regression behind the Sun Bonus page needs a real spread of light conditions across enough measured intervals within one activity before it has anything to fit. Your first ride in flat, unchanging light will show "measuring" the whole way through, and that is the correct answer, not a bug.
- **Instinct and rectangular color devices (like the solar Edge bike computers) are not supported.** The Instinct line's data-field memory budget is a quarter of what this app already uses, on top of a 1-bit display and a non-round screen this project's rendering was never built for. It is a real redesign, not a checkbox.

## Contributing

Issues and pull requests are welcome. If you are proposing a design change, a screenshot or two goes a long way, this app lives and dies by how it actually looks on a real screen.

## License

[PolyForm Noncommercial License 1.0.0](LICENSE.md). Use it, learn from it, fork it, adapt it for your own watch face or data field. Just do not sell it, or a product built on it, or a service built around it. If you are a business and want to do something this license does not allow, open an issue and let's talk.

## Supporting this project ☕

Solar Harvest is free on the Connect IQ Store and always will be. If it made your watch a little more interesting and you would like to say thanks, you can do that here:

> [Ko-fi/texasbe2trill](https://www.ko-fi.com/texasbe2trill)
