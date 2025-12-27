# net-tcp-autotune

一个**安全、可预演、基于环境自动计算的 Linux TCP 调优脚本**（BBR + fq）。

本项目不会盲目把 TCP 参数“拉满”，而是根据 **带宽 / RTT / 内存** 计算 BDP（带宽时延积），在安全上限内进行调优，并提供 **dry-run / apply** 双阶段模式，适合在生产环境中谨慎使用。

---

## ✨ 功能特性

- **自动 RTT 探测**
  - 优先从 SSH 连接中自动获取客户端 IP 进行 ping 测试
  - 失败时自动回退到公共地址（1.1.1.1）

- **基于 BDP 的 TCP Buffer 计算**
  - BDP = 带宽 × RTT
  - 上限取 `min(2 × BDP, 3% 内存, 64MB)`
  - 自动向下桶化至 `{4, 8, 16, 32, 64} MB`

- **安全的冲突处理机制**
  - 备份并注释 `/etc/sysctl.conf` 中的冲突项
  - 备份并移除 `/etc/sysctl.d/*.conf` 中包含冲突键的旧文件
  - 不进行不可逆删除操作

- **dry-run / apply 双模式**
  - 默认 **dry-run**：仅展示将要执行的操作，不修改系统
  - `--apply`：确认后才真正应用修改

- **结果可复核**
  - 显示最终计算与使用的参数
  - 可查看 sysctl 加载顺序与最终生效来源

---

## 🚀 使用方法

### 1️⃣ 预演模式（默认，推荐先运行）
```bash
sudo ./net-tcp-autotune.sh
或显式指定：

bash
复制代码
sudo ./net-tcp-autotune.sh --dry-run
预演模式下脚本只会：

计算 BDP 和 TCP buffer

显示将要修改/备份的文件

展示即将写入的 sysctl 配置

不会对系统做任何修改。

2️⃣ 应用修改
bash
复制代码
sudo ./net-tcp-autotune.sh --apply
执行前需要输入 APPLY 进行二次确认。

3️⃣ 自动化 / 跳过确认
bash
复制代码
sudo ./net-tcp-autotune.sh --apply --yes
适合 cloud-init、自动化部署等场景。

🛠️ 脚本会修改哪些内容
TCP 拥塞控制算法：

text
复制代码
net.ipv4.tcp_congestion_control = bbr
队列调度算法：

text
复制代码
net.core.default_qdisc = fq
TCP Buffer 参数：

text
复制代码
net.core.rmem_max
net.core.wmem_max
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
所有配置统一写入：

text
复制代码
/etc/sysctl.d/999-net-bbr-fq.conf
🔐 安全说明
不会在无备份的情况下修改系统配置

不会在 dry-run 模式下写入或应用任何参数

不会强制覆盖未知来源的 sysctl 文件

对 sysctl --system 和 tc 操作做了容错处理

📦 运行环境要求
Linux 内核 ≥ 4.9（推荐 ≥ 5.x，支持 BBR）

root 权限

已安装 iproute2（用于 tc）

适用于主流发行版：

Debian / Ubuntu

CentOS / AlmaLinux / Rocky Linux

Arch Linux

🧠 设计理念
本项目的目标不是“极限优化”，
而是：根据当前机器与网络环境，把 TCP 参数调到“合理且安全”的状态。

避免拍脑袋式调参

避免无上限 buffer 占用

更适合长期运行的服务器和 VPS

📄 License
MIT License

欢迎使用、修改和分发本项目代码，但请自行评估风险并对使用结果负责。
