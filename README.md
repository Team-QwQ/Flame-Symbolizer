# Flame-Symbolizer

面向 release 环境的火焰图符号化工具：通过 `/proc/<pid>/maps` 与宿主机符号目录定位地址所属模块，再使用 `addr2line` 将 stackcollapse 输出中的 `0x...` 地址替换为 `function (file:line)`。

## 使用方式
1. 准备数据：
	 - stackcollapse 文本（例如 `perf script | stackcollapse-perf.pl` 的输出）。
	 - 同一进程的 `/proc/<pid>/maps` 文件。
	 - 存放符号化 ELF 的目录（可多层 sysroot，脚本支持 `--symbol-dir path/to/sysroot` 并按顺序、多次声明）。
2. 执行脚本：

```bash
./scripts/resolve-stacks.sh \
	--maps /tmp/sample.maps \
	--symbol-dir /opt/sysroot \
	--toolchain-prefix aarch64-linux-gnu- \
	--addr2line-flags "-f -C" \
	--location-format short \
	--input collapsed.txt \
	--output collapsed.resolved.txt
```

默认读取 stdin / 写入 stdout，可级联进/出管道（如 `... | resolve-stacks.sh --maps ... | flamegraph.pl > flame.svg`）。

### 选项要点
- `--toolchain-prefix`：交叉工具链前缀（如 `aarch64-linux-gnu-`），用于调用 `addr2line`、`readelf` 等；如需自定义 `addr2line` 路径，可再用 `--addr2line` 覆盖。
- `--location-format`：符号输出格式；`short`（默认）仅保留文件名与行号，`full` 保留路径，`none` 去掉 file:line。
- `--debug`：打印段表、符号目录命中与地址调整决策到 stderr；stdout 不变。
- ELF 类型自动识别：`ET_EXEC` 直接用运行时地址，`ET_DYN`（PIE/DSO）使用基址调整；无法识别时退化为相对地址。
- 符号缺失告警：找不到模块二进制或符号表缺失时告警一次并缓存，避免刷屏，后续地址保持原样。
- 默认按二进制聚合地址批量调用 `addr2line`，降低子进程开销，同时保持行序与逐行流式输出。

## 开发验证

项目包含一套轻量级夹具，利用假数据与 mock addr2line 覆盖关键路径：

```bash
bash tests/run-fixture.sh
```

该脚本会：
1. 使用 `tests/fixtures/sample.stacks` / `sample.maps`。
2. 通过 `--symbol-dir tests/fixtures/symbols` 定位伪造 ELF。
3. 调用 `tests/fixtures/mock-addr2line.sh` 模拟 `addr2line` 输出。
4. 比对结果与 `tests/fixtures/sample.expected`，确保解析流程稳定。

若需在真实数据上测试，只需替换 `--maps` / `--symbol-dir` / `--input` 参数，并提供可执行的 `addr2line`。脚本会在无法找到匹配模块或符号时输出 `[WARN]`，但保持流水线继续执行。