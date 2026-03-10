import logging
import math
from pygeoapi.process.base import BaseProcessor, ProcessorExecuteError

LOGGER = logging.getLogger(__name__)

PROCESS_METADATA = {
    "version": "1.0.0",
    "id": "zonal-stats",
    "title": "Zonal Statistics",
    "description": "Computes descriptive statistics over a list of numeric values within a defined zone.",
    "keywords": ["statistics", "zonal", "analysis", "aggregation"],
    "links": [],
    "inputs": {
        "zone": {
            "title": "Zone",
            "description": "A GeoJSON Polygon defining the zone of interest.",
            "schema": {"type": "object"},
            "minOccurs": 1,
            "maxOccurs": 1,
        },
        "values": {
            "title": "Values",
            "description": "A list of numeric values to compute statistics over.",
            "schema": {"type": "array", "items": {"type": "number"}, "minItems": 1},
            "minOccurs": 1,
            "maxOccurs": 1,
        },
    },
    "outputs": {
        "result": {
            "title": "Zonal Statistics Result",
            "schema": {"type": "object", "contentMediaType": "application/json"},
        }
    },
    "jobControlOptions": ["sync-execute", "async-execute"],
    "outputTransmission": ["value"],
}


class ZonalStatsProcessor(BaseProcessor):
    def __init__(self, processor_def):
        super().__init__(processor_def, PROCESS_METADATA)

    def execute(self, data, outputs=None):
        zone = data.get("zone")
        if not zone or not isinstance(zone, dict):
            raise ProcessorExecuteError("'zone' must be a GeoJSON Polygon object")
        if zone.get("type") != "Polygon":
            raise ProcessorExecuteError("'zone' must be a GeoJSON Polygon geometry")
        if "coordinates" not in zone or not zone["coordinates"]:
            raise ProcessorExecuteError("'zone' must have valid coordinates")

        values = data.get("values")
        if not values or not isinstance(values, list):
            raise ProcessorExecuteError("'values' must be a non-empty list of numbers")
        try:
            values = [float(v) for v in values]
        except (TypeError, ValueError):
            raise ProcessorExecuteError("All items in 'values' must be numeric")

        count  = len(values)
        total  = sum(values)
        minimum = min(values)
        maximum = max(values)
        mean   = total / count
        std_dev = math.sqrt(sum((v - mean) ** 2 for v in values) / count)
        sorted_vals = sorted(values)
        mid = count // 2
        median = (sorted_vals[mid-1] + sorted_vals[mid]) / 2 if count % 2 == 0 else sorted_vals[mid]

        return "application/json", {
            "type": "ZonalStatisticsResult",
            "zone_summary": {
                "geometry_type": zone["type"],
                "vertex_count": len(zone["coordinates"][0]),
            },
            "statistics": {
                "count":   count,
                "sum":     round(total, 6),
                "min":     round(minimum, 6),
                "max":     round(maximum, 6),
                "mean":    round(mean, 6),
                "median":  round(median, 6),
                "std_dev": round(std_dev, 6),
                "range":   round(maximum - minimum, 6),
            },
        }

    def __repr__(self):
        return f"<ZonalStatsProcessor> id={self.metadata['id']}"
