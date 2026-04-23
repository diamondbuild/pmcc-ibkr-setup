# PMCC Radar — IBKR VPS setup

Installer + proxy for the [PMCC Radar](https://github.com/diamondbuild/pmcc-radar) app.

## What this does

Runs on a cheap VPS (DigitalOcean $4/mo droplet). Gives the Streamlit app
real-time options data, portfolio visibility, and true greeks from IBKR —
all through a tiny authenticated REST proxy.

Architecture:

```
Streamlit Cloud (PMCC Radar) ──HTTPS──▶ This VPS:
                                          • FastAPI proxy (port 8765)
                                          • IB Gateway (port 4002 paper)
                                          • IBC (keeps Gateway logged in)
                                       ──▶ IBKR servers
```

## One-line install

SSH into a fresh Ubuntu 24.04 box as root, then:

```bash
curl -fsSL https://raw.githubusercontent.com/diamondbuild/pmcc-ibkr-setup/main/install.sh | bash
```

The script prints your proxy API token at the end. Save it.

## Next: configure IBC

After the installer finishes, edit `/opt/ibc/config.ini` with your IBKR
credentials (paper first, always). Then:

```bash
systemctl start pmcc-gateway
curl http://localhost:8765/health
```

Full walkthrough in the main app repo.
