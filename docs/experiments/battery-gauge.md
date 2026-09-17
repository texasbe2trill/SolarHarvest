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
| `battery_raw` | 15 | float, record | The battery level as the watch gives it |

Nothing on the watch looks different. Both also chart in Garmin Connect as "Battery Days (raw)" and "Battery (raw)".

## Reading the result

Record one ordinary activity of 20 minutes or more, then look at the two fields in the FIT file (`tools/check_fit.py` lists developer fields).

- **Either value moves between whole percent steps:** the field can read the battery several times finer. The interval fit that already exists would then have several gaps per walk, and Sun Bonus could be measured from a handful of short activities.
- **Both sit still between steps:** the whole percent gauge is all there is. Measuring what the sun is worth then needs a watcher that sees the whole day, which a data field cannot be.

## Not for release

These two fields are diagnostics. They should not ship in a store build as they are.
