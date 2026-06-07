#!/bin/bash

set -euo pipefail

export X_BEARER_TOKEN="YOUR_X_API_BEARER_TOKEN"

exec /usr/bin/ruby /home/YOUR_WEBHOST_USER/scripts/update_spacex_x_cache.rb
