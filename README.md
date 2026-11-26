# MissingBox

一个极简的 macOS 菜单栏 [mihomo](https://github.com/MetaCubeX/mihomo) / [sing-box](https://github.com/SagerNet/sing-box) 客户端。

## 为什么做这个

mihomo 与 sing-box 内核本身就能托管 Web 面板（mihomo 的 `external-ui` / [metacubexd](https://github.com/MetaCubeX/metacubexd)，sing-box v1.14+ 原生 `api` 服务托管的 [sing-box-dashboard](https://github.com/SagerNet/sing-box-dashboard)），把节点、连接、规则、测速都已经做得很好了。可现在的客户端大多还要自己再造一个面板，功能重复，体积和复杂度也跟着上去了——内核：我自己有面板啊？

MissingBox 的想法很简单：**只做内核做不了的事，其余的交给内核和它自带的面板。**

- 管理内核进程、切换内核、配置文件、订阅更新、覆写、TUN 授权这类「客户端」的活，由 MissingBox 负责
- 查看连接、规则、测速这类「面板」的活，一键打开内核托管的面板即可；内核日志另有轻量查看窗口
- 日常最常用的操作（切换模式、切换节点、开关网卡代理）放在菜单栏里，不用打开面板

没有主窗口，没有 Dock 图标，只有一个菜单栏图标。

## 功能

- **双内核切换**：内置最新 mihomo alpha 与 sing-box alpha（v1.15+）内核，可在「更多 → 内核」随时切换；两套内核的配置、覆写、工作目录和 Wi-Fi 规则各自独立，互不干扰
- **内核托管面板**：
  - **mihomo**：一键打开 mihomo 托管的面板，自动带上地址和密钥，默认使用 metacubexd（也可通过 `external-ui-url` 更换）
  - **sing-box**：通过原生 `api` 服务（`127.0.0.1:9098`）托管官方 `sing-box-dashboard`，并提供「复制面板密钥」方便首次连接；同时通过 `clash_api`（`127.0.0.1:9097`）驱动菜单栏快捷操作
- **配置管理**：支持订阅链接和本地配置文件（mihomo 为 YAML，sing-box 为标准 JSON）；订阅可自动更新（默认采用订阅提供的 `profile-update-interval`）；可在应用内编辑本地配置、查看订阅配置
- **配置校验**：导入、编辑、更新配置以及保存配置覆写时，都会先用对应内核（`mihomo -t` / `sing-box check`）完整校验，配置有问题不会被应用；全局覆写保存时只校验 YAML / JSON 格式
- **覆写**：分为「配置覆写」（只对单个配置生效）和「全局覆写」（对所有配置生效），按深度合并规则合并
- **菜单栏快捷操作**：切换代理模式（规则 / 全局 / 直连）、在策略组中切换节点（显示延迟）、解除锁定（mihomo）、关闭所有连接、开关系统代理、重启内核
- **网卡代理（TUN）**：每个内核只需授权一次；mihomo 开启时自动补全 fake-ip DNS（配置已显式指定其他 `enhanced-mode` 时除外）；sing-box 按 v1.15 规范管理 `tun` 入站（不写入已废弃的 `stack` 字段）
- **核心日志**：从菜单打开日志窗口，实时查看当前内核日志（`Home/mihomo.log` 或 `Home-sing-box/sing-box.log`，每次启动时清空）
- **按 Wi-Fi 切换**：为每个 Wi-Fi 网络（另有一组设置适用于所有其他网络）分别指定配置文件、TUN 模式和代理模式；定位服务权限（macOS 读取 Wi-Fi 名称所必需）只在该功能开启时请求
- **与面板同步**：在面板中修改模式、切换节点等操作会同步回菜单栏，下次重启内核仍然保留
- **开机自启**

## 系统要求

- macOS 15 或更高版本
- Apple 芯片（M 系列），不支持 Intel

## 安装

1. 在 [Releases](../../releases) 下载最新版本，将 MissingBox 拖入「应用程序」。每个版本只提供一个 DMG：

   | 文件 | 说明 |
   | --- | --- |
   | `MissingBox-x.y.z-arm64.dmg` | 内置 mihomo alpha 与 sing-box alpha 内核，适用于 Apple 芯片 |

2. 应用未经公证，首次打开前需要移除隔离属性：

   ```sh
   xattr -cr /Applications/MissingBox.app
   ```

   或者首次打开被拦截后，在「系统设置 → 隐私与安全性」中点击「仍要打开」。

### 内核

DMG 内置的 mihomo alpha 与 sing-box alpha 内核在首次启动时会被复制到内核目录，无需其他操作。内核目录中已有对应文件时不会覆盖，所以之后更新 MissingBox 不会替换你自己的内核；想换成新版附带的内核，删掉内核目录中的 `mihomo` 或 `sing-box` 再重新打开 MissingBox 即可。

想自己选择内核版本时，按以下步骤放入：

1. 从 [mihomo Releases](https://github.com/MetaCubeX/mihomo/releases) 下载 `mihomo-darwin-arm64-*.gz`，或从 [sing-box Releases](https://github.com/SagerNet/sing-box/releases) 下载 `sing-box-*-darwin-arm64.tar.gz`（需包含 `with_clash_api` 标签，官方发行版默认包含）并解压
2. 在菜单栏中点击「更多 → 打开内核目录」，把解压出的可执行文件放进去并分别**命名为 `mihomo` 或 `sing-box`**
3. 赋予执行权限并移除隔离属性：

   ```sh
   cd ~/Library/Application\ Support/com.ayanami.MissingBox/Core
   chmod +x mihomo sing-box
   xattr -d com.apple.quarantine mihomo sing-box
   ```

4. 菜单栏「更多 → 内核」中会显示各内核版本，切换内核并添加配置后就会自动启动

以后升级内核只需替换对应文件，然后点击「更多 → 重启内核」。如果开启了网卡代理，替换后会重新请求一次授权。

## 使用说明

### 配置覆写

覆写内容在 mihomo 下为 YAML 映射、在 sing-box 下为标准 JSON 对象，会按以下顺序合并到配置上：

```
配置文件 → 配置覆写 → 全局覆写 → MissingBox 的设置（模式、TUN、控制接口等）
```

合并规则（YAML 与 JSON 一致）：

- 映射 / 对象逐键递归合并，其余值直接替换
- 列表 / 数组用 `+key` 插入到原列表之前，用 `key+` 追加到原列表之后

例如 mihomo（YAML）让自定义规则优先于订阅中的规则：

```yaml
+rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
```

例如 sing-box（JSON）前置自定义路由规则：

```json
{
  "route": {
    "+rules": [
      { "domain_suffix": ["example.com"], "outbound": "direct" }
    ]
  }
}
```

### 网卡代理

创建虚拟网卡需要 root 权限。首次开启时，MissingBox 会弹出系统的管理员授权对话框，把当前内核文件设为 root 所有并加上 setuid 位，之后不再需要授权。替换内核文件或首次为另一内核开启网卡代理时会再次请求授权。

### 文件位置

所有数据都在 `~/Library/Application Support/com.ayanami.MissingBox/` 中：

| 路径 | 说明 |
| --- | --- |
| `Core/mihomo`、`Core/sing-box` | 内核可执行文件 |
| `Home/`、`Home-sing-box/` | 各内核工作目录，存放 Geo 数据、规则集、缓存、面板等 |
| `Home/mihomo.log`、`Home-sing-box/sing-box.log` | 各内核日志，每次启动时清空 |
| `Profiles/`、`Profiles-sing-box/` | 各内核配置文件，文件名即配置名称 |
| `Overrides/`、`Overrides-sing-box/` | 各内核配置覆写 |
| `Override.yaml`、`Override-sing-box.json` | 各内核全局覆写 |

### 安全性

- 控制接口只监听本机回环地址（`127.0.0.1:9097`；sing-box 原生面板服务监听 `127.0.0.1:9098`），密钥在首次启动时随机生成
- 面板路径同样随机生成
- 最终配置通过环境变量（mihomo 的 `CLASH_CONFIG_STRING`）或标准输入（sing-box 的 `-c stdin`）交给内核，密钥和节点信息不会出现在进程参数中

## 从源码构建

需要 Xcode 27 或更高版本（工程格式 `objectVersion 110`，项目使用 Swift 6.2 和 Icon Composer 图标）。

```sh
git clone <仓库地址>
cd MissingBox
open MissingBox.xcodeproj
```

依赖（[Yams](https://github.com/jpsim/Yams)）通过 Swift Package Manager 自动拉取。

### 本地化

界面文本位于字符串目录 `MissingBox/Localizable.xcstrings` 与 `MissingBox/InfoPlist.xcstrings`，键名沿用英语，目前只提供简体中文翻译，应用固定使用简体中文界面。

### 发布

在 Actions 页面手动运行 Release 工作流，填写版本号（如 `1.0.0`，留空只做测试构建）。工作流只允许从 `main` 分支发布：先构建 arm64 DMG（ad-hoc 签名、不公证），成功后自动提交版本号、创建 `v*` tag，并把 `main` 与 tag 推回仓库、创建 Release。

构建时同时下载最新的 mihomo alpha 与 sing-box alpha 内核。中间产物作为 Artifact 保留 1 天，正式 DMG 由 Release 长期保存。

## 致谢

- [mihomo](https://github.com/MetaCubeX/mihomo)
- [sing-box](https://github.com/SagerNet/sing-box) & [sing-box-dashboard](https://github.com/SagerNet/sing-box-dashboard)
- [metacubexd](https://github.com/MetaCubeX/metacubexd)
- [Yams](https://github.com/jpsim/Yams)
- ClashBar、[clash-verge-rev](https://github.com/clash-verge-rev/clash-verge-rev)：参考了 TUN 授权与 DNS 处理的思路

## 许可证

[GPL-3.0](LICENSE)
