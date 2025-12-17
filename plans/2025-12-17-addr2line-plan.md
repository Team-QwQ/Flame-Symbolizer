# addr2line 符号化脚本实施计划

## 范围与参考
- 目标：实现一套可多次执行的 shell 脚本，依据 maps + 符号目录将 stackcollapse 输出中的地址替换为函数名。
- 规范：依据 [specs/addr2line-symbolizer.md](specs/addr2line-symbolizer.md)。

## 假设与不在范围内
- 假设：
  - 用户能提供同一次采样所得的 stackcollapse 文本、对应的 `/proc/<pid>/maps` 文件以及至少一个包含符号表的目录。
  - 符号目录中存放的是与设备二进制一致的带符号产物，且文件名或相对路径能与 maps 关联。
- 不在范围：
  - 不生成或修改 maps / stackcollapse 数据。
  - 不实现 GUI、服务端 API 或跨平台封装，仅提供 shell 可执行脚本。
  - 不处理非十六进制地址、非 stackcollapse 格式的火焰图输入。

## 实施阶段与步骤
1. **脚本骨架与参数解析**
   - 使用 POSIX Shell（bash）编写 `scripts/resolve-stacks.sh`，支持 `--maps`、`--symbol-dir`（可多次）、`--addr2line`、`--addr2line-flags`、`--input`/`--output`（默认为 stdin/stdout）。
   - 明确帮助信息与错误码，确保缺失必需参数时立即退出。

2. **基础管线实现**
   - 逐行读取输入，解析 `;` 分隔的帧与尾部计数，识别纯地址帧。
   - 建立地址缓存，避免重复调用 `addr2line`。
   - 保持输出格式与输入一致，仅替换命中的地址。

3. **maps 解析与符号目录匹配**
   - 解析 maps 文件，构建按地址范围查找的段表（按起始地址排序）。
   - 基于段表命中结果推导模块路径，按声明顺序在 `--symbol-dir` 列表中查找匹配文件（先视 maps 路径为 sysroot，下沉到仅文件名）。
   - 找不到时输出 `[WARN]` 信息并跳过替换。

4. **addr2line 调用与结果处理**
   - 组合 `addr2line` 命令行（支持自定义路径与 flags），传入“实际地址 = 原地址 - 段起始”。
   - 解析返回的函数名、源文件与行号，若为 `??:0` 或命令失败则保留原地址。
   - 对成功解析的结果进行适度格式化（如 `function (file:line)`），并缓存。

5. **校验与辅助脚本**
   - 编写示例输入/输出以及 sanity-test 脚本，至少覆盖：
     - 正常解析（maps 路径直接可用）。
     - 需通过 `--symbol-dir` 匹配的场景。
     - 未找到符号时输出警告但不中断。
   - 更新 README 或新增文档片段说明使用方式。

## 依赖与风险
- 依赖：`addr2line` 可执行文件（可配置路径）；shell 运行环境（bash, coreutils, awk/sed/grep）。
- 风险：
  - maps 与 stackcollapse 不匹配导致偏移错误——需在脚本中检测无段命中时给出提示。
  - 大型输入导致性能瓶颈——通过缓存与尽量少的子进程调用缓解。

## 验证策略
- 单元式验证：使用人工构造的 maps + 对应 ELF，确认地址偏移正确。
- 集成验证：以真实 stackcollapse 样本跑脚本，确保输出可被 flamegraph.pl 正常消费。
- 错误路径：刻意删除 symbol-dir 中的文件，观察脚本是否输出警告但继续执行。

## 审批状态
- `/do` 阶段已执行完毕：脚本、夹具与 README 更新全部落地。
- 自动化夹具 (`tests/run-fixture.sh`) 因终端环境 `ENOPRO` 错误暂未在此环境跑通，待终端恢复后执行一次以完成最终验证。
