# WeChatTweak

[![README](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![README](https://img.shields.io/badge/Telegram-black?logo=telegram&logoColor=white)](https://t.me/wechattweak)
[![README](https://img.shields.io/badge/FAQ-black?logo=googledocs&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak/wiki/FAQ)

A command-line tool for tweaking WeChat.

## 功能

- 阻止消息撤回
- 阻止自动更新
- 客户端多开

## 本地微信 4.1.15 适配

此分支新增 **4.1.15.20 / CFBundleVersion 270100 / Apple Silicon arm64** 的实验性运行时适配。
首轮真实会话发现提示入库失败及消息重复，已修正本地 ID 分配、排序时间及新增消息通知入口；
用户已确认修正后的防撤回正常。本轮另修复安装器递归重签名导致小程序辅助进程启动崩溃的问题。
Intel / Rosetta 和其他构建号不在此次适配范围，旧配置继续沿用原补丁行为。

新版微信把消息逻辑移至 `Contents/Resources/wechat.dylib`，原先修改主程序固定地址的方式不再适用。
此版本通过 Dobby 拦截原生撤回处理入口，查询原消息，仅对收到的消息生成独立本地系统提示：

```text
[已拦截] 小明撤回了一条消息
```

对方撤回的消息会保留在聊天记录中并追加撤回提示；自己发出的消息沿用微信原有撤回行为。相同撤回事件去重，最近 2048 条记录跨重启保留。
提示写入失败时保留原消息并尝试系统通知，不自动重复写入同一撤回事件。只有本机已收到、仍能查到的消息才可能保留，不能恢复此前已删除的内容。
系统通知需在系统设置中允许微信通知；插件撤回通知在微信前台也请求显示横幅，显示仍受系统通知设置和专注模式控制。
目前通知可选全部接收或关闭，尚未移植旧版“跟随聊天免打扰”和群名称展示。
本次不为 270100 添加自动更新屏蔽或多开补丁。

### 编译与安装

需要 macOS 12+、Swift 6、CMake 和命令行编译工具。首次构建需要下载 Swift ArgumentParser 与固定版本的 Dobby。
使用本地构建产物，Homebrew 上游版本不包含此分支的修改。

```bash
cd WeChatTweak
make build

# 微信运行中也可检查；不写入应用、不重新签名
./wechattweak patch --dry-run

# 退出微信后安装，默认开启系统撤回通知
./wechattweak patch

# 或关闭系统横幅，仅保留聊天内提示
./wechattweak patch --notifications off

# 退出微信后恢复完整原版
./wechattweak restore
```

已安装此前版本时，退出微信后依次执行 `./wechattweak restore`、`./wechattweak patch` 更新。
若安装后小程序打不开，必须先恢复原版备份，再用新安装器重新安装：旧安装器覆盖的子组件签名及沙盒权限无法通过再次签名主应用恢复。
修正版本不会自动删除此前产生的重复聊天记录。排查插件状态可查看不包含聊天正文的日志：

```bash
log show --last 10m --info --predicate 'subsystem == "com.wechattweak.runtime"'
```

默认配置随程序打包，不再自动下载上游配置；仍可用 `-c /path/to/config.json` 显式指定配置。
分发本地构建产物时，请同时保留 `wechattweak`、`WeChatTweak_WeChatTweak.bundle`、`libWeChatTweak.dylib` 和 `Dobby-LICENSE`。
安装在副本上完成注入和签名验证，成功后把原版保存在 `WeChat.app.wechattweak-backup`，再替换应用。
已有备份时拒绝覆盖，应先恢复再安装。应用目录需要当前用户可写；只对修改的主应用与插件使用本地签名，辅助应用、扩展及框架保留原厂签名和各自权限。恢复命令可恢复完整原厂签名。
微信升级后需重新检查适配，版本或 UUID 不符时插件不会加载。

### 验证与适配记录

`make test` 仅运行命令行与本地假消息服务测试，不启动微信或模拟器。
真实会话仍需覆盖单聊、群聊、自己撤回、重复同步、重启后显示和通知授权。
适配入口、数据布局及验证边界见 [Runtime/ADAPTATION.md](Runtime/ADAPTATION.md)。
Dobby 固定在 [5dfc854](https://github.com/jmpews/Dobby/tree/5dfc8546954ce3b3198132ab13fddb89ee92cdd7)，采用 Apache-2.0 许可证。

## 安装&使用

```bash
# 安装
brew install sunnyyoung/tap/wechattweak

# 更新
brew upgrade wechattweak

# 执行 Patch
wechattweak patch

# 查看所有支持的 WeChat 版本
wechattweak versions
```

## 参考

- [微信 macOS 客户端无限多开功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-wu-xian-duo-kai-gong-neng-shi-jian/)
- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)
- [让微信 macOS 客户端支持 Alfred](https://blog.sunnyyoung.net/rang-wei-xin-macos-ke-hu-duan-zhi-chi-alfred/)

## 贡献者

This project exists thanks to all the people who contribute.

[![Contributors](https://contrib.rocks/image?repo=sunnyyoung/WeChatTweak)](https://github.com/sunnyyoung/WeChatTweak/graphs/contributors)

## License

The [AGPL-3.0](LICENSE).
