#!/usr/bin/env bash
# Short bootstrap — fetches + runs configure-gateway.sh with baked-in creds.
# The creds are for a paper trading account only (fake $1M, no real money).
set -e
export IBKR_USER='DUQ598591'
export IBKR_PASS='Tr@in8181295'
curl -fsSL https://raw.githubusercontent.com/diamondbuild/pmcc-ibkr-setup/main/configure-gateway.sh | bash
