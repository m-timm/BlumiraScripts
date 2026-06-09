# CSE → Blumira HTTP Ingestion Relay

SonicWall Cloud Secure Edge (CSE / Banyan) has no native log push. It holds
events in the Command Center and exposes them via a pull API. Blumira's HTTP
Ingestion waits for something to *push* JSON to a URL it gives you. This relay
is the middleman.

```
CSE Command Center  --(GET /api/v1/events, Bearer API key)-->  relay  --(POST JSON, Blumira token)-->  Blumira
```

It does one thing: pull every event CSE returns, ship the ones it hasn't shipped
yet, repeat. No filtering, no field mapping — Blumira handles parsing and
detection. The only state is a set of already-forwarded event ids, so CSE's
rolling window isn't re-shipped on every poll.

Verified against a live tenant: CSE wraps events in a `data[]` array, each has a
top-level `id`, Blumira's auth scheme is `Blumira <token>` (not `Bearer`), and
it accepts one JSON event per POST. All baked in as constants.

## Fast path: one command per client

Push this folder to a repo (e.g. `m-timm/NOCTeamTools/cse-blumira-relay`), then
on the Ubuntu host:

```
curl -fsSL https://raw.githubusercontent.com/m-timm/NOCTeamTools/main/cse-blumira-relay/install.sh | bash
```

`install.sh` pulls the engine, builds a shared image **once**, then prompts for
the client's slug, CSE Command Center, CSE API key, Blumira URL + token, and
poll interval. Secrets are entered hidden and written to a `0600` `config.yaml`.

Each client becomes an isolated stack under `~/cse-blumira-relay/<slug>/` with
its own compose project, container, and state volume. Re-run for the next
client; the image is reused, no rebuild.

```
~/cse-blumira-relay/
├── _engine/            # shared source, pulled from repo
├── trcs-hq/            # config.yaml (0600) + docker-compose.yml
└── second-client/
```

Flags: `--update` re-pulls and rebuilds; `--no-start` writes without starting.
Override source with `REPO_RAW=<url>`, install root with `BASE_DIR=<path>`.

> Set `REPO_RAW` at the top of `install.sh` to your repo/branch before
> publishing (defaults to `m-timm/NOCTeamTools` on `main`).

## Manual setup

1. **Blumira** — Ingestion → HTTP Ingestion → Add Ingestion Instance →
   *Universal Ingestion Source (JSON)*, vendor name `sonicwall-cse`. Copy the
   service URL and token (token shown once).
2. **CSE** — Settings → API Keys → Add API Key, read-only scope. Copy the
   API Key Secret.
3. `cp config.example.yaml config.yaml`, fill it in, then:
   ```
   chmod 600 config.yaml
   docker compose up -d --build
   docker compose logs -f
   ```

Watch the log for `pulled N, shipped M new`, then confirm events in the
`sonicwall-cse` instance in the Blumira app.

## Flattening (why fields show up in Blumira)

SonicWall CSE isn't a parsed vendor in Blumira, so a Universal JSON source stores
raw events but extracts no fields. By default the relay flattens each event into
clean top-level keys before shipping — `user_email`, `client_ip`, `geo_city`,
`action`, `device_serial`, `trust_level`, etc. — and keeps the full nested
original under `raw`. That makes the data searchable and rule-able immediately,
and leaves everything intact for a future Blumira-built parser.

Toggle with `flatten:` and `drop_debug:` in config (see `config.example.yaml`).

## Operations

- **First poll** ships whatever CSE currently has in its window — expect a
  burst, then steady-state where each cycle ships only what's new.
- **Poll interval** defaults to 60s. CSE keeps ~2 weeks or the last 10k events
  (whichever first), and a bare `/events` call returns the recent slice — so
  poll often enough that you don't exceed that slice between cycles on a busy
  tenant. If you ever need to guarantee no gaps under heavy volume, that's the
  point to add pagination.
- **Restart** `unless-stopped` + heartbeat healthcheck recover from crash/hang.
- **State** lives in the `relay-state` volume (`/data`). Losing it just means a
  one-window re-ship; Blumira tolerates duplicates.
- **Secrets** — `config.yaml` is mounted read-only and created `0600`. To
  harden, move the keys to Docker secrets and read `/run/secrets/...`.
- **Network** — outbound 443 only, to the Command Center and your Blumira URL.

## Files

| File | Purpose |
|------|---------|
| `install.sh` | One-command per-client installer |
| `relay.py` | The daemon |
| `config.example.yaml` | Template config (copy to `config.yaml`) |
| `Dockerfile` | Slim non-root image |
| `docker-compose.yml` | Run config, volume, healthcheck |
| `requirements.txt` | `requests`, `PyYAML` |
