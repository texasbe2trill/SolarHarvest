"""Add catching_percent/sun_elevation to a real, already-Connect-accepted FIT
file, so a new developer field can be checked on Garmin Connect (via its
Import Data page) without recording another real activity first.

Values are not fabricated: sun_elevation is the real NOAA solar position
(ported from SolarGeometry.mc) evaluated at each record's own real GPS
position and timestamp, and catching_percent is derived from that elevation
and the record's own real solar_intensity, exactly as FitRecorder.mc computes
it live. projected_hours is deliberately left out - it depends on a measured
battery drain rate, and a flat-battery activity has no honest value to give it
(the real device would have skipped it too).

Requires the `fit_tool` package (pip install fit_tool) - a decode+encode FIT
SDK, unlike the read-only libraries more commonly recommended for this.

Usage:
    python3 augment_fit_for_connect_test.py <source.fit> <output.fit>

Two fit_tool quirks to know about if this needs extending later:
  * A message's `.definition_message` is set on decode. from_data_message()
    returns it as-is if present, so appending a developer field to a decoded
    message and re-encoding silently drops the append unless
    `message.definition_message` is reset to None first - only on messages
    actually touched, not the whole file (resetting it everywhere separately
    corrupts nothing, but it is is unnecessary and worth avoiding).
  * `DeveloperField.get_values()` applies the field's scale/offset even when
    the FIT wire format is signaling "not set" (encoded as the sentinel
    255/127) - it reads those two bytes as literal numbers instead. This
    project's fields never declare a scale/offset, so reading a developer
    field back for further computation must use `.encoded_values[0]`, not
    `.get_values()[0]`; the same applies to inspecting fields via a REPL.
"""
import datetime
import math
import sys

from fit_tool.base_type import BaseType
from fit_tool.developer_field import DeveloperField
from fit_tool.fit_file import FitFile
from fit_tool.fit_file_builder import FitFileBuilder
from fit_tool.profile.messages.developer_data_id_message import DeveloperDataIdMessage
from fit_tool.profile.messages.field_description_message import FieldDescriptionMessage
from fit_tool.profile.messages.record_message import RecordMessage

MIN_USEFUL_ELEVATION = 15.0


def elevation_degrees(epoch_seconds, lat_deg, lon_deg):
    """Port of SolarGeometry.elevationDegrees (NOAA equations)."""
    dt = datetime.datetime.fromtimestamp(epoch_seconds, datetime.timezone.utc)
    doy = dt.timetuple().tm_yday
    hour = dt.hour + dt.minute / 60.0 + dt.second / 3600.0
    g = (2.0 * math.pi / 365.0) * (doy - 1 + ((hour - 12.0) / 24.0))
    cos_g, sin_g = math.cos(g), math.sin(g)
    cos_2g, sin_2g = math.cos(2 * g), math.sin(2 * g)
    cos_3g, sin_3g = math.cos(3 * g), math.sin(3 * g)
    eq_time = 229.18 * (0.000075 + 0.001868 * cos_g - 0.032077 * sin_g
                         - 0.014615 * cos_2g - 0.040849 * sin_2g)
    decl = (0.006918 - 0.399912 * cos_g + 0.070257 * sin_g - 0.006758 * cos_2g
            + 0.000907 * sin_2g - 0.002697 * cos_3g + 0.00148 * sin_3g)
    lat_rad = math.radians(lat_deg)
    true_solar_minutes = (hour * 60.0) + eq_time + (4.0 * lon_deg)
    hour_angle = ((true_solar_minutes / 4.0) - 180.0) * (math.pi / 180.0)
    cos_zenith = (math.sin(lat_rad) * math.sin(decl)
                  + math.cos(lat_rad) * math.cos(decl) * math.cos(hour_angle))
    cos_zenith = max(-1.0, min(1.0, cos_zenith))
    return 90.0 - math.degrees(math.acos(cos_zenith))


def available_fraction(elevation_deg):
    if elevation_deg <= 0.0:
        return 0.0
    return max(0.0, min(1.0, math.sin(math.radians(elevation_deg))))


def clear_sky_percent(intensity, elevation_deg):
    if elevation_deg < MIN_USEFUL_ELEVATION:
        return None
    available = available_fraction(elevation_deg)
    if available <= 0.0:
        return None
    return max(0, min(100, int(intensity / available + 0.5)))


def rounded_elevation(elevation):
    return int(elevation + (-0.5 if elevation < 0.0 else 0.5))


def make_field_description(dev_index, field_num, name, base_type, units):
    fd = FieldDescriptionMessage()
    fd.developer_data_index = dev_index
    fd.field_definition_number = field_num
    fd.fit_base_type_id = base_type
    fd.field_name = name
    fd.units = units
    fd.native_field_num = 255
    return fd


def main(src_path, out_path):
    ff = FitFile.from_file(src_path)
    messages = [rec.message for rec in ff.records]

    dev_id_msg = next(m for m in messages if isinstance(m, DeveloperDataIdMessage))
    dev_index = dev_id_msg.developer_data_index

    last_fd_idx = max(i for i, m in enumerate(messages) if isinstance(m, FieldDescriptionMessage))
    new_descriptions = [
        make_field_description(dev_index, 11, 'catching_percent', BaseType.UINT8, '%'),
        make_field_description(dev_index, 12, 'sun_elevation', BaseType.SINT8, 'deg'),
    ]
    messages[last_fd_idx + 1:last_fd_idx + 1] = new_descriptions

    added_elevation = 0
    added_catching = 0
    for m in messages:
        if not isinstance(m, RecordMessage):
            continue
        if m.position_lat is None or m.position_long is None or m.timestamp is None:
            continue

        elev = elevation_degrees(m.timestamp / 1000.0, m.position_lat, m.position_long)

        elev_field = DeveloperField(field_id=12, name='sun_elevation', base_type=BaseType.SINT8,
                                     units='deg', size=1, developer_data_index=dev_index)
        elev_field.set_values([rounded_elevation(elev)])
        m.developer_fields.append(elev_field)
        m.definition_message = None
        added_elevation += 1

        intensity_field = m.get_developer_field_by_name('solar_intensity')
        if intensity_field is None:
            continue
        catching = clear_sky_percent(intensity_field.encoded_values[0], elev)
        if catching is None:
            continue
        catch_field = DeveloperField(field_id=11, name='catching_percent', base_type=BaseType.UINT8,
                                      units='%', size=1, developer_data_index=dev_index)
        catch_field.set_values([catching])
        m.developer_fields.append(catch_field)
        m.definition_message = None
        added_catching += 1

    print(f'elevation added to {added_elevation} records, catching added to {added_catching} records')

    builder = FitFileBuilder(auto_define=True)
    builder.add_all(messages)
    builder.build().to_file(out_path)
    print('wrote', out_path)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(f'usage: {sys.argv[0]} <source.fit> <output.fit>')
    main(sys.argv[1], sys.argv[2])
