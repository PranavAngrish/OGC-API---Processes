import logging
from pygeoapi.process.base import BaseProcessor, ProcessorExecuteError
from shapely.geometry import Point, mapping
from shapely.ops import transform
import pyproj

LOGGER = logging.getLogger(__name__)

PROCESS_METADATA = {
    "version": "1.0.0",
    "id": "buffer",
    "title": "Buffer",
    "description": "Creates a circular buffer polygon around a given point.",
    "keywords": ["buffer", "geometry", "proximity"],
    "links": [],
    "inputs": {
        "latitude":  {"title": "Latitude",  "schema": {"type": "number", "minimum": -90,  "maximum": 90},     "minOccurs": 1, "maxOccurs": 1},
        "longitude": {"title": "Longitude", "schema": {"type": "number", "minimum": -180, "maximum": 180},    "minOccurs": 1, "maxOccurs": 1},
        "distance":  {"title": "Distance",  "schema": {"type": "number", "minimum": 1,    "maximum": 100000}, "minOccurs": 1, "maxOccurs": 1},
    },
    "outputs": {
        "result": {
            "title": "Buffer Polygon",
            "schema": {"type": "object", "contentMediaType": "application/geo+json"},
        }
    },
    "jobControlOptions": ["sync-execute", "async-execute"],
    "outputTransmission": ["value"],
}


class BufferProcessor(BaseProcessor):
    def __init__(self, processor_def):
        super().__init__(processor_def, PROCESS_METADATA)

    def execute(self, data, outputs=None):
        try:
            lat      = float(data["latitude"])
            lon      = float(data["longitude"])
            distance = float(data["distance"])
        except (KeyError, TypeError, ValueError) as e:
            raise ProcessorExecuteError(f"Invalid input: {e}")

        if not (-90 <= lat <= 90):
            raise ProcessorExecuteError("latitude must be between -90 and 90")
        if not (-180 <= lon <= 180):
            raise ProcessorExecuteError("longitude must be between -180 and 180")
        if not (1 <= distance <= 100000):
            raise ProcessorExecuteError("distance must be between 1 and 100000 metres")

        to_mercator = pyproj.Transformer.from_crs("EPSG:4326", "EPSG:3857", always_xy=True).transform
        to_wgs84    = pyproj.Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True).transform

        buffer_wgs84 = transform(to_wgs84, transform(to_mercator, Point(lon, lat)).buffer(distance))

        return "application/geo+json", {
            "type": "Feature",
            "geometry": mapping(buffer_wgs84),
            "properties": {"centre_latitude": lat, "centre_longitude": lon, "distance_metres": distance},
        }

    def __repr__(self):
        return f"<BufferProcessor> id={self.metadata['id']}"
