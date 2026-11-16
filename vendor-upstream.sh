#!/bin/bash
# 登录上游官方源码（zlib）到 upstream/；CI 每次也会自动拉
git clone --depth 1 -b acompmobile https://github.com/assaultcube/AC.git upstream

echo "done: upstream/$(git -C upstream rev-parse --short HEAD)"
