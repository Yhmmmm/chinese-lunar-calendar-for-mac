#!/bin/bash
# 事件打开服务的本地回归：不执行 Calendar 自动化，不请求权限，不读取真实日程。
set -euo pipefail
cd "$(dirname "$0")/.."
calendar_test_dir=$(mktemp -d)
trap 'rm -rf "$calendar_test_dir"' EXIT
calendar_test_target="$(uname -m)-apple-macosx13.0"

swiftc -target "$calendar_test_target" -parse-as-library -emit-object -emit-module -whole-module-optimization \
    -module-name LunarCore -emit-module-path "$calendar_test_dir/LunarCore.swiftmodule" \
    Sources/LunarCore/*.swift -o "$calendar_test_dir/LunarCore.o"
# 编译真实 AgendaEvent 类型；测试不会初始化 SystemCalendarStore 或调用 CalendarEventOpener.open。
swiftc -target "$calendar_test_target" -parse-as-library -I "$calendar_test_dir" \
    Sources/WanNianLi/SystemCalendarStore.swift Sources/WanNianLi/CalendarEventOpener.swift \
    Tests/CalendarEventOpenerRegressionTests.swift "$calendar_test_dir/LunarCore.o" \
    -o "$calendar_test_dir/calendar-event-opener-regressions"
"$calendar_test_dir/calendar-event-opener-regressions"
