# test-stress
嵌入式 Linux 系统三路并发压力老化测试脚本，同时压测 CPU、内存和 GPU，用于出厂前整机稳定性验证。

## 功能
- CPU 满负载老化（stress-ng 全算法轮询）
- 内存 负载老化（占用 80% 可用内存，全模式读写压测）
- GPU 长时间渲染老化（glmark2-es2）
- 实时监控：CPU 使用率/温度/频率、内存占用、GPU 使用率
- 测试结束后自动关机

## 必要环境
| 依赖 | 说明 |
|------|------|
| `stress-ng` | CPU / 内存压力测试 |
| `glmark2-es2` | GPU 渲染测试（OpenGL ES 2.0） |
| `bc` | 浮点运算 |
| `figlet` | 结果大字输出 |

安装示例（Debian/Ubuntu）：
```bash
stress-ng：
tar -xvzf stress-ng-0.18.06.tar.gz
cd stress-ng-0.18.06
make -j$(nproc)
sudo make install

figlet:
tar -xvzf figlet-2.2.5.tar.gz
cd figlet-2.2.5
make
sudo make install

glmark2-es2：
sudo dpkg -i glmark2-es2.deb

bc:
sudo dpkg -i bc_arm64.deb
```

## 运行
```bash
chmod +x test_stress_*.sh
sudo ./test_stress_*.sh
```
