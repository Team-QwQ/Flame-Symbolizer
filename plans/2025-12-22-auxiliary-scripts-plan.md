# 辅助脚本实施计划（heaptrack 转栈 + 泄漏火焰图）

## 范围与依据
- 范围：整理 `scripts/auxiliary/` 下的 heaptrack→stack 与泄漏火焰图生成脚本，补齐帮助、校验与文档。
- 规范来源：[specs/2025-12-22-auxiliary-scripts-spec.md](../specs/2025-12-22-auxiliary-scripts-spec.md)

## 假设 / 不在范围
- 环境具备 Bash、heaptrack 工具链、flamegraph.pl。
- 不改动主符号化脚本 `resolve-stacks.sh`，仅围绕辅助脚本。

## 计划步骤
1) 补齐 CLI 帮助与默认值
   - 为两个脚本实现 `-h/--help`，描述参数、默认值、依赖。
2) 依赖与输入输出校验
   - 检查必需工具存在；输入文件存在；输出目录可写；`mktemp` 失败兜底。
3) 行为对齐规范
   - `heaptrack-to-raw-stack.sh` 支持 `--cost-type {leaked|allocations|temporary|peak}`（默认 leaked），调用 `heaptrack_interpret` + `heaptrack_print --flamegraph-cost-type <type> -F`；临时文件清理。
   - `render-leak-flamegraph.sh` 接受相同的 `--cost-type`，根据类型设置 `flamegraph.pl` 的标题与计数名（如 leaked→bytes，allocations→allocs，temporary/peak 选择合适的计数名）；支持 `FLAMEGRAPH_BIN` 覆盖。
4) 文档更新
   - README 辅助脚本章节同步参数/默认值/依赖。
   - 如有需要，在脚本内打印成功摘要。

## 验证策略
- 手动：针对示例 heaptrack.raw.gz（或空跑依赖检查）验证成功/失败路径；检查生成的 stack 文件与 SVG 存在且非空。
- 帮助：运行 `-h/--help` 确认输出用法文本。

## 状态
- 当前阶段：/plan
- 下一步：按计划执行并更新文档。
