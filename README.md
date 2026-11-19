# AssaultCube → iOS 源码级移植

上游游戏源码（官方，zlib 授权）：https://github.com/assaultcube/AC —— 分支 `acmobile`（官方移动版，SDL2 + GL4ES + OpenAL + 触屏 UI，原本只出 Android）。

**本仓库 = 完整的 iOS 移植工程**（iOS 平台层 + 依赖构建 + 引擎编译 + IPA 打包 + CI），不含上游大型资源包，CI 会自动拉取上游源码。

## 为什么不需要 “Windows 兼容层”
AssaultCube 本身就是跨平台 C++（SDL2 + OpenGL 1.x + OpenAL），没有 Windows 专属依赖。所以是**源码直接重编译**，不是 Wine / 虚拟机 / 兼容层。

- 图形：OpenGL 1.x 调用 → **gl4es** 转成 OpenGL ES 2.0（iOS 原生）
- 窗口/输入/音频：SDL2 (UIKit 后端) + OpenAL-Soft (CoreAudio)
- 移动端代码路径：编译时定义 `__ANDROID__`，复用上游已有的触屏 UI / 横屏逻辑
- iOS 平台层：`ios/main.m`（SDL_UIKitRunApp、数据目录 chdir、gl4es 手动初始化）

## iOS 原生触控层（Liquid Glass）

`acmobile` 的触屏 HUD 是画进 GL 场景的图集图标，经 gl4es 转译后在 iPhone Air / iOS 27 上不可见，且默认「双击开火、滑动跳跃」，导致跳跃、开枪、换枪全都用不了。本工程改用 **UIKit 原生控制层**（`ios/MobileUI.mm`）：

- **可见按钮**：开火、跳跃、蹲下、换弹、上一把 / 下一把、狙击镜、主武器 / 副武器 / 手雷 / 近战、计分板、菜单
- **动态摇杆**：左半屏按下即出现，8 方向移动，松手回位（`TOUCH_GAME_LEFTSIDE_*`）
- **空区域穿透**：按钮以外的区域仍然交给 SDL，拖动右半屏照常转视角
- **设置页**（左上齿轮）：Liquid Glass 卡片（iOS 26+ `UIGlassEffect`，低版本自动回退毛玻璃）
  - 显示/隐藏触屏按键、按钮大小、不透明度、左手模式
  - 视角灵敏度
  - **外接键盘键位**：点一行 → 按一下键盘 → `bind KEY action` 立即生效
  - **触屏按键功能**：把任意屏幕按钮改成别的功能
  - 恢复默认键位

## 外接键盘 / 鼠标

- 蓝牙 / USB 键盘走 iOS 的 `GCKeyboard`（SDL 2.33 已内置），本工程把触摸层拦截掉的 `SDL_KEYDOWN/UP`、`SDL_MOUSEMOTION`、`SDL_MOUSEBUTTON*` 全部转发回引擎，WASD、空格、Shift、1-4、鼠标键直接可用。
- 说明：iPhone 的 iOS 本身不向普通 App 暴露蓝牙鼠标指针，只有 iPadOS 有指针；键盘是完整支持的。

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
ios/MobileUI.mm       UIKit 原生触控层（液态玻璃按钮 / 摇杆 / 设置页 / 键位）
ios/ac_bridge.cpp     原生层 → 引擎的按键与命令桥
ios/ios-input.patch   打到上游引擎的输入补丁（键鼠转发 / 原生层挂载点）
ios/Info.plist        bundle 配置（横屏、文件共享、arm64）
stubs/android/log.h   Android 日志 API 到 stderr 的桩
.github/workflows/stage1.yml
```

## 当前状态
启动期崩溃已修复（gl4es 初始化）；iOS 原生触控层、设置页、外接键盘转发已接入，真机 iPhone Air / iOS 27 验收中。
