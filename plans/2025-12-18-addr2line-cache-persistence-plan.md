# addr2line 持久化缓存实施计划（2025-12-18）

## 范围与参考
- 范围：在不改变默认 CLI 行为的前提下，为地址符号化脚本添加可选的持久化缓存（读取/写回），并与现有批处理、告警/调试逻辑协同工作。
- 参考规范：
  - [specs/addr2line-cache-persistence.md](../specs/addr2line-cache-persistence.md)
  - [specs/addr2line-symbolizer.md](../specs/addr2line-symbolizer.md)
  - [specs/addr2line-performance.md](../specs/addr2line-performance.md)

## 假设与不在范围
- 假设：
  - 运行环境具备 bash、coreutils、readelf/addr2line（或通过 toolchain 前缀获取）。
  - 符号目录与 maps 能正常命中二进制（缓存仅加速已可解析路径）。
- 不在范围：
  - 不实现并行或远程缓存；不处理跨主机同步。
  - 不更改默认输出格式和告警风格；未指定 cache 文件时行为与现状一致。

## 计划步骤
1) **参数与格式定稿**
   - 新增 `--cache-file`、`--cache-mode {on,off,refresh}` 参数，默认 mode=on；无 cache-file 时仅内存缓存。
   - 确定缓存落盘格式为 NDJSON（每行一条记录），包含键、值与元信息；定义版本号与字段名，便于向后兼容。
2) **加载路径**
   - 启动时若提供可读的 cache 文件，逐行解析 NDJSON，统计加载条目；用户自担文件有效性，脚本不再做命令/格式有效性额外校验，无法解析的行跳过并继续。
   - 基于 binary_identity（优先 build-id；退化 mtime+size+inode）验证命中有效性；失效条目不进入内存缓存。
3) **命中与写入策略**
   - 符号化前先查询持久化缓存；`status=ok/miss/warn-*` 都可命中以跳过重复调用。
   - 新条目（含 miss/warn）写入内存待 flush；`cache-mode off` 禁止读/写，`refresh` 在退出时重写全量（去除失效）。
4) **写回与原子性**
   - 退出前将新增/更新条目写临时文件并 `rename` 覆盖；不可写时一次性 `[WARN]` 并降级为内存模式。
   - `refresh` 模式下基于当前内存视图重写文件（过滤失效）。
5) **可观测性与调试**
   - 在 debug 或 stderr 概要输出：是否启用缓存、加载条数、命中/失效/写回条数、降级原因。
6) **测试与验证**
   - 保持现有夹具无回归（未指定 cache-file）。
   - 新增用例：
     - 指定 cache-file 运行两次，同一输入第二次 addr2line 调用显著减少，输出一致。
     - 缓存文件不可读/不可写或格式版本不符，输出一次警告后降级，处理仍完成。
     - 替换二进制（mtime 或 build-id 变更）后缓存失效重新解析，输出正确。
     - `cache-mode off` 不读不写；`refresh` 读后重写，去除失效记录。

## 影响面
- 代码：`scripts/resolve-stacks.sh`（参数解析、缓存加载/命中/写回）、测试夹具可能新增。
- 文档：README 或 design 文档补充缓存使用说明与调试输出说明。

## 依赖与风险
- 依赖：可用的 `jq` 不强制；解析 NDJSON 需用 bash 内建/`sed`/`awk` 解析，需谨慎转义。
- 风险：
  - 大文件加载耗时：需流式逐行解析并限制字段解析开销。
  - 并发写入/跨文件系统 `rename` 失败：通过单进程假设和临时文件+rename；文档提示尽量同一文件系统。
  - 身份校验错误导致命中脏数据：必须优先使用 build-id，失败时组合 mtime+size+inode，并在 debug 中输出校验依据。

## 验证策略
- 现有 fixture 回归：未指定缓存参数时结果一致。
- 新增集成脚本/fixture：验证缓存命中、刷新、失效重建、错误降级。
- 性能：记录 addr2line 调用次数（debug 计数）前后对比，确保缓存生效。

## 审批状态与下一步
- 状态：/plan 待审。
- 审批后进入 `/do` 按上述步骤实现；若落盘格式或字段需调整，将回到 `/plan` 更新后再执行。
