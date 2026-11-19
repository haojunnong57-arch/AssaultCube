#!/bin/bash
# Compile AssaultCube engine (acmobile) for iOS arm64 and link the app binary
set -e
IOS_MIN=${IOS_MIN:-17.0}
AC=upstream

if [ ! -d "$AC" ]; then
  # Pin the acmobile commit the iOS patch is written against.
  git init "$AC"
  git -C "$AC" remote add origin https://github.com/assaultcube/AC.git
  git -C "$AC" fetch --depth 1 origin a2fa75e0297d449a45ea0ed8eed7583512d25f43
  git -C "$AC" checkout --detach FETCH_HEAD
fi
if [ ! -d gl4es ]; then
  git clone --depth 1 https://github.com/ptitSeb/gl4es.git gl4es
fi

# Apply the iOS input patch (native touch layer hook + hardware keyboard/mouse
# forwarding). Skipped when the upstream tree already carries it.
if git -C "$AC" apply --check "$PWD/ios/ios-input.patch" 2>/dev/null; then
  git -C "$AC" apply "$PWD/ios/ios-input.patch"
  echo "[PATCH] ios-input.patch applied" >> build.log
else
  echo "[PATCH] ios-input.patch already applied (or does not match upstream)" >> build.log
fi

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="xcrun --sdk iphoneos clang   -arch arm64 -isysroot $SDK -mios-version-min=$IOS_MIN"
CXX="xcrun --sdk iphoneos clang++ -arch arm64 -isysroot $SDK -mios-version-min=$IOS_MIN"
INC="-Istubs -Igl4es/include -Iprefix/include/SDL2 -Iprefix/include -I$AC/source/src -I$AC/source/include -I$AC/source/enet/include"
CFLAGS="-D__ANDROID__ -O2"
CXXFLAGS="-D__ANDROID__ -std=c++11 -fno-rtti -fno-exceptions -fsigned-char -fstack-protector -O2"

# iOS patches (perl: macOS sed chokes on '|' inside s|||)
# 1) absolute base dir is not needed: we chdir() into the .app bundle in main.m
perl -pi -e 's{\Q"/storage/emulated/0/Android/data/net.cubers.assaultcube/files/"\E;}{NULL;}' "$AC/source/src/stream.cpp"
# 2) writable profile dir (Documents/assaultcube) comes from the environment
perl -pi -e 's{\Q#define DEFAULTPROFILEPATH "profile"\E}{#define DEFAULTPROFILEPATH (getenv("AC_HOME_DIR")?getenv("AC_HOME_DIR"):"profile")}' "$AC/source/src/main.cpp"
# 3) SDL >= 2.0.18 no longer ships KMOD_LMETA/KMOD_RMETA; use the GUI (Cmd) equivalents
perl -pi -e 's{\Q#define MOD_KEYS_CTRL (KMOD_LMETA|KMOD_RMETA)\E}{#define MOD_KEYS_CTRL (KMOD_LGUI|KMOD_RGUI)}' "$AC/source/src/platform.h"
# 4) system() is unavailable on iOS; this desktop server-wizard path is never used by the mobile client
perl -pi -e 's{system\(argstr\.getbuf\(\)\);}{printf("(iOS: wizard server launch not supported)\\n");}' "$AC/source/src/wizard.cpp"

echo "--- patched sources ---" >> build.log
grep -n "absbasedir =" -A3 "$AC/source/src/stream.cpp" >> build.log 2>&1 || true
grep -n "AC_HOME_DIR" "$AC/source/src/main.cpp" >> build.log 2>&1 || true
grep -n "KMOD_LGUI" "$AC/source/src/platform.h" >> build.log 2>&1 || true

mkdir -p objs

SRCS="crypto audiomanager autodownload client clientgame clients2c command console docs editing entities http log main menus touch/touch oggstream openal packetqueue physics protocol rendercubes rendergl renderhud rendermodel renderparticles rendertext rndmap scoreboard serverms server serverbrowser shadow soundlocation soundscheduler stream texture tools water weapon wizard world worldio worldlight worldocull worldrender zip bot/bot bot/botmanager bot/bot_ai bot/bot_util bot/bot_waypoint bot/ac_bot bot/ac_bot_ai"

pids=""
for f in $SRCS; do
  o="objs/$(echo "$f" | tr '/' '_').o"
  ( echo "[CXX] $f" >> build.log; $CXX $CXXFLAGS $INC -c "$AC/source/src/$f.cpp" -o "$o" >> build.log 2>&1 ) &
  pids="$pids $!"
  if [ $(echo $pids | wc -w) -ge 4 ]; then
    for p in $pids; do wait $p || exit 1; done
    pids=""
  fi
done
for p in $pids; do wait $p || exit 1; done

CSRCS="list callbacks compress host packet peer protocol unix win32"
for f in $CSRCS; do
  echo "[CC] enet/$f" >> build.log
  $CC $CFLAGS $INC -c "$AC/source/enet/$f.c" -o "objs/enet_$f.o" >> build.log 2>&1 || exit 1
done

echo "[OBJCXX] ios/main.m" >> build.log
$CXX -x objective-c++ -fobjc-arc -arch arm64 -isysroot $SDK -mios-version-min=$IOS_MIN \
  -Iprefix/include/SDL2 -Igl4es/include -c ios/main.m -o objs/ios_main.o >> build.log 2>&1 || exit 1

echo "[OBJCXX] ios/MobileUI.mm" >> build.log
$CXX -x objective-c++ -fobjc-arc -std=c++11 -arch arm64 -isysroot $SDK -mios-version-min=$IOS_MIN \
  -Iprefix/include/SDL2 -Igl4es/include -c ios/MobileUI.mm -o objs/ios_mobileui.o >> build.log 2>&1 || exit 1

echo "[CXX] ios/ac_bridge.cpp" >> build.log
$CXX $CXXFLAGS -Iprefix/include/SDL2 -c ios/ac_bridge.cpp -o objs/ios_bridge.o >> build.log 2>&1 || exit 1

echo "[LINK] AC" >> build.log
$CXX objs/*.o -o AC \
  -Lprefix/lib -lSDL2 -lSDL2_image -lopenal -logg -lvorbis -lvorbisfile \
  -Lgl4es/lib -Lgl4es/lib/Release -lGL \
  -lz -lsqlite3 -liconv \
  -framework UIKit -framework OpenGLES -framework QuartzCore -framework CoreAudio \
  -framework AudioToolbox -framework AVFoundation -framework CoreMotion -framework GameController \
  -framework CoreHaptics -framework Metal -framework CoreGraphics -framework CoreFoundation \
  -framework Foundation -framework ImageIO -framework Security -framework CoreBluetooth \
  -framework CoreServices -framework CoreMedia -framework CoreVideo -framework CFNetwork \
  >> build.log 2>&1 || { tail -40 build.log; exit 1; }

ls -lh AC >> build.log
file AC >> build.log
