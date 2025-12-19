# resolve-stacks 进度日志增强实施计划

## 范围
- 实施规范：[specs/2025-12-19-progress-logging-spec.md](../specs/2025-12-19-progress-logging-spec.md)
- 文件范围：`scripts/resolve-stacks.sh`

## 假设 / 非目标
- 仅在 `DEBUG_MODE=1` 时输出新增日志；默认模式无变化。
- 不调整符号化逻辑、批处理策略或 CLI。
- 使用固定步长的阶段性日志，避免过度噪声。

## 步骤计划
1) 为 `first_pass_collect` 添加基于输入行计数的阶段性进度日志（debug only），包含累计行数；在阶段结束输出汇总。
2) 为 `run_batch_symbolization` 添加基于批次数/地址数的阶段性进度日志（debug only）；在阶段结束输出汇总。
3) 为 `second_pass_emit` 添加基于输出行计数的阶段性进度日志（debug only）；在阶段结束输出汇总。
4) 轻量自检：本地运行 `tests/run-fixture.sh` 或等效最小输入，确认无额外输出（非 debug）且 debug 下出现进度日志。

## 验证策略
- 非 debug 路径：运行 `tests/run-fixture.sh`，输出应与基准一致。
- Debug 路径：运行同一脚本加 `--debug`，观察 stderr 出现三阶段的进度/汇总日志（步长输出 + 收尾）。

## 风险与缓解
- 频率过高导致日志噪声：使用合适步长（如 10k 行/批）；可集中汇总。
- 计数与现有全局计数器冲突：使用局部计数器，必要时复用已存在的安全计数变量。

## 审批与下一步
- 当前阶段：`/plan`
- 待确认后进入 `/do` 执行。
