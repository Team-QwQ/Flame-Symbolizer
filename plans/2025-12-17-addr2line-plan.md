# addr2line 符号化脚本实施计划

## 范围与参考
- 目标：实现一套可多次执行的 shell 脚本，依据 maps + 符号目录将 stackcollapse 输出中的地址替换为函数名，包含 ELF 类型自动识别、输出格式开关与调试/告警策略。
- 规范：依据 [specs/addr2line-symbolizer.md](specs/addr2line-symbolizer.md)，性能优先，当前版本仅支持文件输入/输出，不支持 stdin/stdout 流式。

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
   - 扩展 `scripts/resolve-stacks.sh` 参数：必选 `--maps`，可选多次 `--symbol-dir`，`--toolchain-prefix`（调用 `addr2line`/`readelf` 等前缀），`--addr2line` 覆盖，`--addr2line-flags` 透传，`--input`/`--output`（均为文件路径，不支持 stdin/stdout），`--location-format`（none|short|full，默认 short），`--debug`。
   - 完善帮助与错误码，缺失必需参数、输入不可读、输出目录不存在、输入输出路径相同等场景立即退出。

2. **基础管线实现**
   - 逐行解析 stackcollapse 行，分割帧与计数，识别 `0x` 地址帧。
   - 地址级缓存避免重复解析；输出格式保持一致，仅替换可解析的地址。
   - 根据 `--location-format` 控制输出：默认函数名+短文件名+行号；`none` 去掉 file:line；`full` 带路径文件名。

3. **maps 解析与符号目录匹配**
   - 解析 maps 构建段表，基于地址命中获得模块路径与偏移。
   - 在 `--symbol-dir` 中按顺序查找：先在目录根平铺按文件名查找；若失败再按 sysroot 思路拼接 maps 原始绝对路径；再失败则退化为 basename 匹配；缓存命中结果。
    - 告警策略：
       - 找不到模块二进制：输出警告，对同一模块仅告警一次以降噪。
       - 找到二进制但符号缺失/addr2line 返回 `??`：允许多次告警以暴露可能的二进制问题；仍不屏蔽该模块的后续地址解析。

4. **ELF 类型识别与 addr2line 调用**
   - 使用 toolchain 前缀的 `readelf`（或缺省）探测模块 ELF 类型：`ET_EXEC` 直接用运行时地址；`ET_DYN`/DSO 使用基址调整（start - offset）；无法识别类型时退化为相对地址策略。
   - 组合 `addr2line` 调用（前缀或覆盖路径 + 透传 flags），失败或返回 `??` 视为未解析并保留原地址。
   - 解析结果按所选输出格式渲染并缓存。

5. **调试与可见性**
   - `--debug` 模式下输出段表、符号目录命中、地址调整决策到 stderr；输出文件不受影响。
   - 默认模式下：缺失二进制警告一次/模块；符号缺失/`??` 可多次警告，但后续地址仍会尝试解析。

6. **校验与文档**
   - 增补/调整测试夹具，覆盖：非 PIE `ET_EXEC` 绝对地址解析、PIE/DSO 相对地址解析、符号缺失一次性告警、location-format 三种模式、toolchain 前缀与显式 addr2line 覆盖。
   - 更新 README/使用说明，展示新参数与示例。

## 依赖与风险
- 依赖：`addr2line`、`readelf`（可通过工具链前缀获取），bash 及常用 coreutils/grep/sed/awk。
- 风险：
   - maps 与 stackcollapse 不匹配导致偏移错误——需在脚本中检测无段命中时提示并保留原地址。
   - 大型输入导致性能瓶颈——通过缓存与减少子进程调用缓解。
   - 非 PIE/PIE 判断错误导致偏移不准——通过 readelf 探测类型，探测失败时至少退化为相对地址并告警。

## 验证策略
- 单元式验证：构造 ET_EXEC 与 ET_DYN 的样例，确认绝对地址与基址调整路径都正确。
- 集成验证：以真实 stackcollapse 样本跑脚本，验证 location-format 输出、符号缺失一次性告警、toolchain 前缀/覆盖路径。
- 错误路径：刻意缺失符号目录或去除符号表，确保输出警告但不中断，且同段仅告警一次。

## 审批状态
- 当前处于 `/do` 阶段，按本计划实施。
