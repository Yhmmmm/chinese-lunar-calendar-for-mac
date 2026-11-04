#!/bin/bash
# 使用可控事件源验证日期分组、范围缓存和权限状态；不读取真实系统日历。
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library -emit-object -emit-module -whole-module-optimization \
    -module-name LunarCore -emit-module-path "$WORK/LunarCore.swiftmodule" \
    Sources/LunarCore/*.swift -o "$WORK/LunarCore.o"
swiftc -parse-as-library -D DEBUG -I "$WORK" \
    Sources/WanNianLi/SystemCalendarStore.swift Tests/SystemCalendarRegressionTests.swift \
    "$WORK/LunarCore.o" -o "$WORK/system-calendar-regressions"
"$WORK/system-calendar-regressions"
