"""Which 15-minute (policy interval) slot of the day a wake-up belongs to. Pure: no clock, files or devices."""
from datetime import datetime, timedelta


def window(day, time_range, before_minutes, after_minutes):
    """(start, end) of the watch window around a time range on `day`."""
    start = datetime.combine(day, time_range[0]) - timedelta(minutes=before_minutes)
    end = datetime.combine(day, time_range[1]) + timedelta(minutes=after_minutes)
    return start, end


def slot_of(now, time_range, before_minutes, after_minutes, interval_minutes):
    """Slot key ('YYYY-MM-DD#n') when `now`, read at minute precision, is inside the window; None outside it."""
    start, end = window(now.date(), time_range, before_minutes, after_minutes)
    minute = now.replace(second=0, microsecond=0)
    if not start <= minute <= end:
        return None
    return f"{now.date().isoformat()}#{int((minute - start).total_seconds() // 60) // interval_minutes}"
