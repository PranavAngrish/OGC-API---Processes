FROM geopython/pygeoapi:latest

WORKDIR /pygeoapi

# Install into pygeoapi's own virtualenv at /venv
COPY requirements.txt .
RUN /venv/bin/pip install --no-cache-dir -r requirements.txt

COPY processes/ /pygeoapi/processes/
COPY config/pygeoapi-config.yml /pygeoapi-config.yml

ENV PYGEOAPI_CONFIG=/pygeoapi-config.yml
ENV PYGEOAPI_OPENAPI=/pygeoapi-openapi.yml
