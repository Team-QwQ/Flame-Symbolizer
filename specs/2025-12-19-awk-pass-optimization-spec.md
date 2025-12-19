# Bash 行/帧解析优化（awk 方案）规格

## 背景与问题
- `first_pass_collect` 和 `second_pass_emit` 在 Bash 中对每行/每帧做正则与字符串操作（行正则拆分、`trim_whitespace`、`is_hex_address` 等），在数万行、数十万帧场景下 CPU 占比高于符号化阶段。
- 实测 4 万行输入，`run_batch_symbolization` 很快，瓶颈集中在 Bash 逐行逐帧解析。
- 目标是用 `awk` 取代 Bash 循环，降低解析开销，同时保持现有功能与输出一致。

## 目标
- 将两阶段（收集地址 / 回填输出）的核心行帧解析迁移到 `awk`，显著降低 CPU 开销。
- 保持功能等价：
  - 识别 `stack_part count` 形式的行；
  - 按 `;` 拆帧，去空白；
  - 非十六进制帧原样保留；
  - 计数、行序、分隔符与现有输出一致；
  - `RAW_ADDR_SEEN` 全局去重逻辑继续生效；
  - 调用管线（maps 匹配、addr2line 批处理、缓存回填）保持不变。
- 与现有 CLI、调试输出兼容；不改变 `--location-format` 等选项语义。

## 非目标
- 不改 `run_batch_symbolization`、maps 段查找、addr2line 调用逻辑。
- 不引入并行或多进程处理。
- 不改变告警/日志格式（除非不可避免的微调在 DEBUG 下）。

## 方案概述
- 使用 `awk`（POSIX awk 或 gawk）处理两遍文本，Bash 负责 maps/addr2line/缓存：
  1) **第一遍收集**：
     - 按行解析 `stack_part count`，分号拆帧、trim，标记空行/异常行；
     - 非十六进制帧直接记录；十六进制帧经 RAW_ADDR_SEEN 去重后写入“唯一地址列表”；
     - 将分帧结果、计数、行类型写入“帧临时文件”，供二遍复用，避免再次正则和 trim。
  2) **Bash 处理唯一地址**：读取唯一地址列表，maps 匹配、ELF 判定、相对地址计算、分桶，填充 ADDRESS_CACHE。
  3) **第二遍回填**：
     - 读取帧临时文件，依据 ADDRESS_CACHE 替换十六进制帧，重组行并输出；保留行序/计数/分隔符。
- 接口形态：
  - awk 仅处理文本拆分/标注，不做 maps 查找；与 Bash 通过临时文件交互（帧文件、唯一地址文件）。
  - Bash 保留参数解析、日志、maps/addr2line 逻辑及覆盖输出流程。

## 约束与兼容性
- 保持 `set -euo pipefail` 下可运行。
- 需兼容默认 Debian/Ubuntu 的 `awk`（mawk 或 gawk），不依赖非标准扩展。
- 临时文件应在输入目录或 `/tmp` 创建，需清理。
- DEBUG 模式下仍按 PROGRESS_LOG_EVERY 输出进度，可在 Bash 层保持，减少 awk 内日志。

## 验收标准
- 功能正确性：
  - 现有 fixture `tests/run-fixture.sh` 通过，输出逐字节一致。
  - 与旧实现对同一大输入（至少 40k 行）输出完全一致。
- 性能：
  - 在 ≥40k 行输入上，`first_pass_collect`+`second_pass_emit` 总 CPU 时间相较 Bash 旧循环降低（目标 ≥30%）。
- 兼容性：
  - CLI 行为、调试日志、告警、去重与批处理语义不变。
  - 覆盖模式（省略/相同 output）仍可工作；新增临时文件需正确清理或提示。

## 风险与缓解
- 风险：Bash 与 awk 间状态/缓存同步复杂。
  - 缓解：保持 addr2line、maps、缓存逻辑在 Bash 中，awk 仅负责文本拆分与替换；中间数据格式简单、可 diff。
- 风险：awk 行/帧拆分边界与 Bash 行为不一致（空帧、尾部分号、异常空格）。
  - 缓解：构造包含异常空白、空帧、非数字计数的测试，确保与旧输出一致；必要时在 awk 中复现 Bash 的 trim 逻辑。
- 风险：临时文件泄露。
  - 缓解：使用 `mktemp` 创建并在 Bash `trap` 中清理；失败时提示路径。

## 开放问题
- 中间数据格式：
  - 仅输出唯一地址列表，还是输出行号/帧索引用于回填？（倾向于保持现有缓存思路：先填充 ADDRESS_CACHE，再由第二遍 awk 直接查缓存）。
- 是否保留 Bash 中的进度日志，还是在 awk 中实现行计数后回传？（倾向于 Bash 层计数触发日志）。
- 大文件场景下，是否需要流式（避免两遍读取）？当前仍两遍读取，接受内存开销。
