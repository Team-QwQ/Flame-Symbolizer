# 符号解析持久化缓存规格

## 背景与问题
- 同一份 stackcollapse 数据或相似采样常被多次解析；当前缓存仅进程内存态，重复运行仍需全量调用 `addr2line`，浪费时间。
- 需要在不改变输出格式的前提下，将解析结果落盘，下次运行可直接复用，加速处理。

## 目标
- 新增可选的持久化缓存：解析成功/失败结果都可落盘；后续运行可加载并复用，减少 `addr2line`/`readelf` 调用。
- 默认不影响现有行为（未指定缓存文件时保持纯内存缓存）。
- 输出内容、行序、告警风格与主规格一致。

## 非目标
- 不要求跨主机/分布式共享缓存。
- 不引入并行化或网络服务。
- 不存储敏感额外信息（仅符号解析相关元数据）。

## 适用范围
- 适用于可重复运行的输入（文件或可回放数据）。
- 与现有性能规约（地址批处理、流式处理）协同，不应破坏流式输出。

## 模式与参数
- 新增可选参数：`--cache-file <path>` 启用持久化缓存；路径可指向新文件或已有缓存文件。
- 新增可选参数：`--cache-mode {on,off,refresh}`，默认 `on`；`off` 禁用落盘/读取，`refresh` 表示读取后强制重写（用于清理陈旧失效记录）。
- 若未提供 `--cache-file`，即使 `--cache-mode on` 也仅使用内存缓存。
- 若缓存文件不可读/不可写，输出一次 `[WARN]` 并自动降级为内存缓存。

## 数据模型与键空间
- 键：`<binary_identity>|<addr_mode>|<reladdr_hex>|<location_format>|<addr2line_flags>`
  - `binary_identity`：通过实际使用的二进制文件确定，优先使用 `build-id` 或 `elf mtime+size+inode`（至少两项）来检测变化；存储同时记录该二进制的路径（解析后命中的符号文件路径）。
  - `addr_mode`：`abs`（ET_EXEC 直接地址）或 `rel`（ET_DYN/未识别基于段起始的相对地址），以确保偏移方式一致。
  - `reladdr_hex`：传给 `addr2line` 的十六进制地址（不带 `0x` 前缀）。
  - `location_format`：当前符号输出格式（none/short/full）。
  - `addr2line_flags`：实际调用的 flags 字符串（含 demangle 等），避免不同参数串扰。
- 值：
  - `status`: `ok` / `miss` / `warn-missing-binary` / `warn-no-symbol`（可扩展）
  - `symbol`: 当 `status=ok` 时保存完整符号字符串；否则为空。
  - `metadata`: `build-id`、`mtime`、`size`、`script-version`、`created-at`。

## 读写策略
1. **加载阶段**：
   - 若指定 `--cache-file` 且可读，启动时一次性加载；格式采用行分隔 JSON（NDJSON）或简洁 TSV+JSON metadata，需在实现时定稿；若格式/版本不兼容输出一次 `[WARN]` 并忽略。
2. **命中判定**：
   - 仅当 `binary_identity` 匹配当前二进制（通过 build-id 或 mtime+size+inode 比对）时命中；否则视为失效，不使用该条目。
   - 对 `status=miss`/`warn-*` 也可命中，用于跳过已知无符号或缺失二进制的重复调用。
3. **写入阶段**：
   - 运行结束或定期 flush 时将内存中新条目（含 miss）追加/合并写回。
   - 写入需原子性：先写临时文件再 `rename` 覆盖；尽量保持旧文件在失败时不损坏。
   - 若 `--cache-mode off` 不写回；`refresh` 模式可重写全量，使文件去除失效的旧记录（实现可选）。

## 失效与更新
- 当检测到二进制的 `build-id` 或 `mtime+size+inode` 与缓存不符时，该二进制相关条目全部视为失效，不应被使用；可在写回时移除或保留但不命中。
- 允许在写回时去重，保留最新条目（基于 `created-at` 或写回顺序）。

## 可观察性
- 默认输出一次概要（stderr 或 debug 模式可见）：是否启用持久化、缓存条目加载数、命中数、失效数、写回条目数。
- 当缓存文件不可读/写或版本不兼容，输出一次 `[WARN]`，不应中断主流程。

## 兼容性
- 不改变已有 CLI 的默认行为；未启用 `--cache-file` 时逻辑与当前版本一致。
- 输出格式、警告风格与主规格、性能规约一致。

## 验收标准
- 未指定 `--cache-file` 时，现有夹具/性能测试无回归。
- 指定可写的缓存文件运行两次同一输入：第二次 `addr2line` 调用数显著减少（可通过 debug 计数验证），输出与首次一致。
- 当二进制被替换（mtime 或 build-id 变更）后再运行，缓存命中率降为 0，该二进制重新解析，输出仍正确。
- 缓存文件损坏或不可读时，脚本输出 `[WARN]`，继续以内存缓存模式完成解析。

## 风险与未决问题
- 大量条目写回的性能与文件大小，需要格式权衡（NDJSON vs KV）；可能需要压缩。
- 文件锁与并发写入：需评估是否加简单锁（如 `flock`）；不锁可能导致竞争写损坏。
- 跨文件系统的原子 `rename` 保证有限；需告知用户尽量使用同一文件系统。

## 关联文档
- 主规格：[specs/addr2line-symbolizer.md](addr2line-symbolizer.md)
- 性能规约：[specs/addr2line-performance.md](addr2line-performance.md)
- 权重优先启发式：[specs/addr2line-weighted-priority.md](addr2line-weighted-priority.md)
