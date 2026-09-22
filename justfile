# UUTmux 构建与安装。需要 xcodegen 与完整版 Xcode。

_default:
    @just --list

# 构建原生 UUTmux.app，产物在 build/UUTmux.app。
build:
    #!/usr/bin/env zsh
    set -e -u
    command -v xcodegen >/dev/null || { print -u2 "缺少 xcodegen：brew install xcodegen"; exit 1 }
    cd native
    print "生成 Xcode 工程…"
    xcodegen generate >/dev/null
    print "构建 Release…"
    DERIVED="$(mktemp -d)"
    xcodebuild -project UUTmux.xcodeproj -scheme UUTmux \
      -configuration Release -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED" \
      ENABLE_PREVIEWS=NO build >/dev/null
    APP="$DERIVED/Build/Products/Release/UUTmux.app"
    [[ -d "$APP" ]] || { print -u2 "未找到构建产物 $APP"; exit 1 }
    mkdir -p ../build
    rm -rf ../build/UUTmux.app
    cp -R "$APP" ../build/UUTmux.app
    rm -rf "$DERIVED"
    print "完成：build/UUTmux.app"

# 安装 build/UUTmux.app 到 ~/Applications。
install:
    #!/usr/bin/env zsh
    set -e -u
    OUT="build/UUTmux.app"
    DEST="$HOME/Applications/UUTmux.app"
    [[ -d "$OUT" ]] || { print -u2 "未找到 $OUT，请先运行 just build"; exit 1 }
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$OUT" "$DEST"
    print "已安装：$DEST"
    print "首次启动请在系统设置授予 iTerm2 自动化权限。"

# 运行核心逻辑测试。
test:
    swift test --package-path native/UUTmuxCore
