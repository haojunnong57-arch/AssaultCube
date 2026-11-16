# AssaultCube → iOS 源码级移植

上游游戏源码（官方，zlib 授权）：https://github.com/assaultcube/AC —— 分支 `acmobile`（官方移动版，SDL2 + GL4ES + OpenAL + 触屏 UI，原本只出 Android）。

**本仓库 = 完整的 iOS 移植工程**（iOS 平台层 + 依赖构建 + 引擎编译 + IPA 打包 + CI），不含上游大型资源包，CI 会自动拉取上游源码。

## 为什么不需要 “Windows 兼容层”
AssaultCube 本身就是跨平台 C++（SDL2 + OpenGL 1.x + OpenAL），没有 Windows 专属依赖。所以是**源码直接重编译**，不是 Wine / 虚拟机 / 兼容层。

- 图形：OpenGL 1.x 调用 → **gl4es** 转成 OpenGL ES 2.0（iOS 原生）
- 窗口/输入/音频：SDL2 (UIKit 后端) + OpenAL-Soft (CoreAudio)
- 移动端代码路径：编译时定义 `__ANDROID__`，复用上游已有的触屏 UI / 横屏逻辑
- iOS 平台层：`ios/main.m`（SDL_UIKitRunApp、数据目录 chdir、gl4es 手动初始化）

## 关键坑（已验证）
1. gl4es 在 Apple 上定义了 `NO_INIT_CONSTRUCTOR`，**不会自动初始化**，必须由 App 调 `initialize_gl4es()`；且初始化时要 `LIBGL_NOTEST=1`，否则会在无 GL 上下文时探测硬件而崩（已实测崩溃栈：`gl4es_glHint` @ 0x49）。
2. gl4es 动态库在 Apple 零导出符号 → 必须 `-DSTATICLIB=ON`。
3. gl4es 非 Linux 平台不编 `glx.c/fb.c` → 用 `-DNOX11=ON -DNOEGL=ON -DNO_LOADER=ON -DDEFAULT_ES=2`。
4. `attributes.h` 的 alias 属性 Apple 不支持 → 打 `!defined(__APPLE__)` 补丁。
5. macOS `sed -i` 遇到 `|` 分隔符会报错 → 统一用 `perl -pi -e` 打补丁。

## 编译（云端，无需 Xcode 本地）
GitHub Actions：`.github/workflows/stage1.yml`（runner `macos-26`，Xcode 26.6，SDK iphoneos26.5，arm64，min iOS 17.0）。
push 到 `main` 自动触发，产物发到 Release 标签 `build`：

```
https://github.com/haojunnong57-arch/AssaultCube/releases/download/build/AssaultCube-iOS.ipa
```

## 安装
未签名 IPA，用 **Sideloadly** 自签安装（免费 Apple ID 签 7 天，到期重签）。

## 目录
```
ci-deps.sh            依赖静态库构建（SDL2/SDL2_image/gl4es/ogg/vorbis/openal）
ci-engine.sh          引擎编译 + 链接（含 iOS 补丁）
ci-package.sh         打包 Payload/AssaultCube.app → IPA
ci-step.sh            单步日志包裹（失败不断链）
vendor-upstream.sh    拉取上游 acompmobile 源码到 upstream/
ios/main.m            iOS 入口（SDL_UIKitRunApp + 数据目录 + gl4es 初始化）
ios/Info.plist        bundle 配置（横屏、文件共享、arm64）
stubs/android/log.h   Android 日志 API 到 stderr 的桩
.github/workflows/stage1.yml
```

## 当前状态
启动期崩溃已修复（gl4es 初始化）；真机 iPhone Air / iOS 27 验收中。
