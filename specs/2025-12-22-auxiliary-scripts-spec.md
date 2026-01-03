# 辅助脚本规格（heaptrack 转栈 + 泄漏火焰图）

## 背景与问题
- 分析内存泄漏时常用 heaptrack 获取 `*.raw.gz`，需快速转为 stackcollapse/火焰图。
- 现有主符号化脚本 `resolve-stacks.sh` 已就绪，但缺少围绕 heaptrack 的固定流程脚本，使用上分散且缺少规范/帮助。

## 目标
- 提供两个可复用的辅助脚本：
  1) `heaptrack-to-raw-stack.sh`：将 heaptrack 原始数据转为按泄漏字节计数的 stackcollapse 风格文件。
  2) `render-leak-flamegraph.sh`：从 stackcollapse 文件生成以泄漏为主的火焰图 SVG。
- 具备清晰的命令行帮助、默认参数与依赖校验，适合流水线或手动复现。

## 非目标
- 不替代 heaptrack 本身，也不负责采集阶段。
- 不在脚本内做符号化（仍由上游 `resolve-stacks.sh` 负责）。
- 不引入 GUI/服务端，仅保留命令行脚本。

## 功能需求（与当前实现对齐）
- `heaptrack-to-raw-stack.sh`
  - 入参：`<heaptrack.raw.gz> [output_stack_file]`，默认输出 `stack.txt`。
  - 可选参数：`--cost-type {leaked|allocations|temporary|peak}`，默认 `leaked`，用于驱动 `heaptrack_print --flamegraph-cost-type <type>`。
  - 行为：`zcat | heaptrack_interpret` 生成中间文件，再 `heaptrack_print --flamegraph-cost-type <type> -F` 输出栈文件；临时文件会清理。
  - 校验：当前仅校验输入文件存在及 `--cost-type` 合法；不预检 `heaptrack_interpret`/`heaptrack_print`/`zcat` 可用性，缺失时依赖命令失败退出。
  - 帮助：支持 `-h/--help` 输出用法与默认值。
- `render-leak-flamegraph.sh`
  - 入参：`[stack_file] [output_svg]`，默认 `./stack.txt`、`raw-leak.svg`。
  - 可选参数/环境：接受与 `heaptrack-to-raw-stack.sh` 相同的 `--cost-type`（默认 `leaked`），用于决定标题与计数名；允许 `FLAMEGRAPH_BIN` 覆盖 flamegraph.pl 路径。
  - 行为：调用 `flamegraph.pl --colors=mem --title "<cost-type>" --countname=<metric>` 生成 SVG，其中 `<metric>` 与 cost-type 对应（例如 leaked→bytes，allocations→allocs，temporary/peak 使用 bytes）。
  - 校验：校验 stack 文件存在与 `FLAMEGRAPH_BIN` 可执行；未预检其它依赖。
  - 帮助：支持 `-h/--help` 输出用法与默认值。

## 约束与兼容性
- 依赖 Bash、heaptrack 工具链、flamegraph.pl；当前实现未对工具可用性做预检，运行时缺失将直接失败。
- 默认输出文件若已存在，直接覆盖。

## 可观测性
- 成功路径打印摘要（输出路径与 cost-type）；失败路径依赖底层命令错误并以非零退出，未添加额外提示。

## 验收标准
- 对合法输入，两个脚本均成功退出且产生预期输出文件。
- 缺失依赖或输入不存在时，脚本以非零退出并打印明确错误。
- `-h/--help` 可展示使用说明与默认值。
