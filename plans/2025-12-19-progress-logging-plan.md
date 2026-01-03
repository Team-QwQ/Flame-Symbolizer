# resolve-stacks 进度日志增强实施计划

## 范围
- 实施规范：[specs/2025-12-19-progress-logging-spec.md](../specs/2025-12-19-progress-logging-spec.md)
- 文件范围：`scripts/resolve-stacks.sh`

## 假设 / 非目标
- 进度日志在默认路径即以 INFO 级输出；不新增独立开关关闭。
- 不调整符号化逻辑、批处理策略或 CLI。
- 使用固定步长的阶段性日志，避免过度噪声。

## 步骤计划
1) 为 `first_pass_collect` 输出基于输入行计数的阶段性 INFO 进度日志，包含累计行数；在阶段结束输出汇总。
2) 为 `run_batch_symbolization` 输出基于批次数/地址数的阶段性 INFO 进度日志；在阶段结束输出汇总。
3) 为 `second_pass_emit` 输出基于输出行计数的阶段性 INFO 进度日志；在阶段结束输出汇总。
4) 轻量自检：本地运行 `tests/run-fixture.sh` 或等效最小输入，确认默认路径已有 INFO 进度日志，`--debug` 仍可叠加细节，输出无功能回归。

## 验证策略
- 默认路径：运行 `tests/run-fixture.sh`，stderr 应看到三阶段 INFO 进度/汇总日志，功能输出与基准一致。
- Debug 路径：运行同一脚本加 `--debug`，stderr 仍有进度日志并包含附加调试细节。

## 风险与缓解
- 频率过高导致日志噪声：使用合适步长（如 10k 行/批）；可集中汇总。
- 计数与现有全局计数器冲突：使用局部计数器，必要时复用已存在的安全计数变量。

## 审批与下一步
- 当前阶段：`/plan`
- 待确认后进入 `/do` 执行。
