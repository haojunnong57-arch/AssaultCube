#!/bin/bash
# 登录上游官方源码（zlib）到 upstream/；CI 每次也会自动拉
# acmobile, pinned to the commit ios/ios-input.patch is written against
git init upstream
git -C upstream remote add origin https://github.com/assaultcube/AC.git
git -C upstream fetch --depth 1 origin a2fa75e0297d449a45ea0ed8eed7583512d25f43
git -C upstream checkout --detach FETCH_HEAD

echo "done: upstream/$(git -C upstream rev-parse --short HEAD)"
