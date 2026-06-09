FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    RELAY_CONFIG=/config/config.yaml \
    RELAY_STATE_DIR=/data

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY relay.py .

# Run as non-root; the state volume is chowned by compose/entrypoint.
RUN useradd --system --uid 10001 relay && mkdir -p /data && chown relay /data
USER relay

VOLUME ["/data"]

ENTRYPOINT ["python", "/app/relay.py"]
