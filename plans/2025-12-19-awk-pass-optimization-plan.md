# awk 行/帧解析优化计划

## 范围与规格
- 范围：将 `first_pass_collect` / `second_pass_emit` 的行帧解析从 Bash 正则拆分迁移到 awk，以降低 CPU 开销。
- 规格来源：见 [specs/2025-12-19-awk-pass-optimization-spec.md](../specs/2025-12-19-awk-pass-optimization-spec.md)。

## 假设与不在范围
- 假设：目标环境有标准 awk（mawk/gawk），不依赖 GNU 特性；输入依旧为 stackcollapse 规范文本。
- 不在范围：不改 maps 查找、addr2line 批处理、缓存/告警/日志语义；不做并行化。

## 分阶段步骤（可验证）
1) 中间数据流：使用 awk 第一遍生成“帧临时文件”（行类型+计数+帧列表，tab 分隔）和“唯一地址列表”；Bash 保持缓存/分桶流程。
2) 第一遍 awk：实现分帧、trim、hex 判定、RAW 去重，输出帧文件与唯一地址文件，保留进度计数。
3) Bash 处理唯一地址：读取唯一地址文件，maps 匹配、ELF 判定、分桶、填充 ADDRESS_CACHE。
4) 第二遍 awk：读取帧文件，按 ADDRESS_CACHE 回填并重组行，保持行序/计数/分隔符；支持覆盖模式输出。
5) 回归测试：运行 `tests/run-fixture.sh`，并对比优化前后输出一致性。
6) 性能抽样：在 ≥40k 行输入上测量总耗时，与旧 Bash 循环对比（目标解析阶段 ≥30% 降幅），记录一次结果。

## 验证策略
- 必跑：`tests/run-fixture.sh`（输出一致）。
- 一致性：对同一大输入，优化前后输出逐字节一致（可用 `diff`）。
- 性能：简单计时（`/usr/bin/time`) 比较解析阶段总耗时；记录一次对比结果。

## 风险与缓解
- 行/帧边界差异：构造含空帧、尾部分号、异常空格的用例，与旧实现对比，必要时在 awk 中复刻 trim 行为。
- 状态同步复杂：保持 addr2line/mappings/caches 在 Bash，awk 只做拆分+替换；中间文件格式简洁且易 debug。
- 临时文件泄露：使用 `mktemp` 并在 trap 中清理；失败时提示路径。

## 审批与下一步
- 状态：待批准计划。
- 批准后按步骤实施，优先保证输出一致性，再收集一次性能对比数据。
