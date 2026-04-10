#!/usr/bin/env bash
# 判断单行对话是否更像噪声（工具块、代码围栏等），供提取器参考
is_conversation_noise_line() {
    local s="$1"
    case "$s" in
        *'```'*) return 0 ;;
        *'Sender (untrusted'*) return 0 ;;
        *'[tool'*) return 0 ;;
        *'"toolCall"'*) return 0 ;;
    esac
    return 1
}
