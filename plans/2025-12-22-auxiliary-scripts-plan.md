# 辅助脚本实施计划（heaptrack 转栈 + 泄漏火焰图）

## 范围与依据
- 范围：整理 `scripts/auxiliary/` 下的 heaptrack→stack 与泄漏火焰图生成脚本，补齐帮助、校验与文档。
- 规范来源：[specs/2025-12-22-auxiliary-scripts-spec.md](../specs/2025-12-22-auxiliary-scripts-spec.md)

## 假设 / 不在范围
- 环境具备 Bash、heaptrack 工具链、flamegraph.pl。
- 不改动主符号化脚本 `resolve-stacks.sh`，仅围绕辅助脚本。

## 计划步骤（与现状对齐）
1) CLI 帮助与默认值
   - 已实现：两个脚本均支持 `-h/--help`、cost-type 选项与默认值说明。
2) 依赖与输入输出校验
   - 现状：仅校验输入文件存在（两脚本）和 `FLAMEGRAPH_BIN` 是否可执行；未预检 `heaptrack_interpret`/`heaptrack_print`/`zcat`，缺失时依赖命令失败退出。若需完善依赖预检，另行补充。
3) 行为对齐规范
   - 已实现：`heaptrack-to-raw-stack.sh` 支持 `--cost-type`（默认 leaked），使用 `heaptrack_interpret` + `heaptrack_print --flamegraph-cost-type <type> -F`，并清理临时文件。
   - 已实现：`render-leak-flamegraph.sh` 支持相同 `--cost-type`，根据类型设置标题/计数名，支持 `FLAMEGRAPH_BIN` 覆盖。
4) 文档更新
   - 待办：README 辅助脚本章节尚未同步参数/默认值/依赖；如需补充成功摘要或依赖说明，另行更新。

## 验证策略
- 已覆盖：`-h/--help` 输出用法文本；基础 happy path 可手动运行检查文件生成。
- 未覆盖：依赖预检、README 同步后的文档验收（待后续补充）。

## 状态
- 当前阶段：部分落实（脚本功能与帮助已具备），依赖预检与 README 同步尚未完成。
- 如需补完依赖检查/文档，再行提交更新。
