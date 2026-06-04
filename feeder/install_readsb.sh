#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.
#
# This wrapper invokes the upstream readsb installer maintained by wiedehopf
# (https://github.com/wiedehopf/adsb-scripts). readsb itself is licensed
# separately under the GNU GPL — see https://github.com/wiedehopf/readsb.
sudo bash -c "$(wget -O - https://github.com/wiedehopf/adsb-scripts/raw/master/readsb-install.sh)"
