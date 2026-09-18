# Experiment: is there a finer battery gauge?

Branch: `dev/battery-gauge-experiment`

## The problem

Sun Bonus is measured from the gaps between battery steps: how fast one percent went, against how much sun fell in that gap. The watches this field runs on report their level in whole percents, and a fenix 9 Pro Solar in a GPS activity uses about 1.3% an hour. A half hour walk therefore moves the gauge by one step or none, and an activity has to see at least three steps before it can say anything about the sun. Short activities never get there.

This is a limit of the data and not of the arithmetic. With only "did the percent tick, and when" to go on, the best any estimator can do is set by the information in that record. Worked out from eight real recordings, a fit that stands three standard errors clear of zero needs roughly 300 to 700 half hour walks.

## The question

Does the watch expose anything finer than the whole percent?

- `System.getSystemStats().batteryInDays` is a float. If the firmware derives it from a finer fuel gauge, it will move between the whole percent steps.
- `System.getSystemStats().battery` is also a float. On the recordings so far it has only ever moved by exactly 1.0, but it has never been recorded unrounded.

## What this branch does

It records both, every second, unrounded, as two more developer fields in the activity's FIT file:

| Field | Id | Type | What it is |
|---|---|---|---|
| `battery_days` | 14 | float, record | The watch's own days remaining figure |
| `battery_raw` | 15 | float, record | The battery level as the watch gives it (retired after the first walk, see below) |

Nothing on the watch looks different. Both also chart in Garmin Connect as "Battery Days (raw)" and "Battery (raw)".

## The first walk (18 September 2026, fenix 9 Pro Solar, 30 minutes)

`battery_raw` held two values, 56 and 55: the level is whole percents and nothing finer. It answered its question and is retired; its id is reused below, since no store build ever wrote it.

`battery_days` moved 36 times in 30 minutes, about every 52 seconds, in steps of 0.0007 to 0.0021 days (one to three minutes of battery life), 37 distinct values between one percent step and the next. It is about thirty times finer than the percent. What is not yet known is whether it reads the charge or counts down from a modelled rate: the steps vary in size, which a countdown's would not, but on this one walk its slope did not follow the light (the fit came out the wrong way, t of about 2, on five windows). Two or three walks with the watch in full sun for fifteen minutes and under a sleeve for fifteen will settle it: a real gauge slows in the sun by around a third of a day per day of drain.

## What the branch does now

The gauge is measured against, the way the percent steps are, and quoted only past the same evidence gates, so a countdown can never show a bonus and a real gauge shows one after roughly ten deliberate walks or sixty ordinary ones. `BatteryModel.addDays` keeps the first and latest readings while recording, and fits windows of five active minutes, the minutes of life spent an hour against the light in the window. The fit is carried across activities beside the calibration (six numbers after the classic eight under the same storage key; a record from before reads as before). Where the percent steps have no fit, the bonus rests on the gauge's, converted to percent an hour on the watch's own terms: a day of life is the level over the days left.

| Field | Id | Type | What it is |
|---|---|---|---|
| `battery_days` | 14 | float, record | The gauge itself, every second |
| `life_spent` | 15 | float, session | Battery life the activity spent, in minutes, by the gauge |
| `lap_life_spent` | 16 | float, lap | The same, per lap |
| `full_sun_so_far` | 17 | float, record | Full sun minutes so far, to the tenth: the harvest as a rising curve |
| `sun_saving_fine` | 18 | float, session | Minutes of battery life an hour of full sun saves, by the gauge, once the fit passes the gates |

`tools/check_fit.py` reports the gauge on each file, and given several files pools their fits the way the watch does and says how many more such activities the gate needs:

    python3 tools/check_fit.py walk1.fit walk2.fit walk3.fit

## Reading the result

Record one ordinary activity of 20 minutes or more, then look at the two fields in the FIT file (`tools/check_fit.py` lists developer fields).

- **Either value moves between whole percent steps:** the field can read the battery several times finer. The interval fit that already exists would then have several gaps per walk, and Sun Bonus could be measured from a handful of short activities.
- **Both sit still between steps:** the whole percent gauge is all there is. Measuring what the sun is worth then needs a watcher that sees the whole day, which a data field cannot be.

## Not for release

These two fields are diagnostics. They should not ship in a store build as they are.

The battery page's RATE chip shows the gauge's own reading of the activity's drain from its tenth active minute, marked ~, until two percent steps give a counted one. Connect's labels were made plain at the same time (Battery Level, Battery Days Left, Battery Drain Rate, Sun Caught (of possible), Sun Saving (percent) and Sun Saving (battery life)) and the charts ordered sun first, battery second.

Open question: whether Connect IQ caps an app's developer fields at sixteen. This branch declares nineteen. If the FIT from the first walk lacks ids 16 to 18, that is the cap, and three fields have to go or fold into others.
