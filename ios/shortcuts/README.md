# PasteLink 正式版复制快捷指令模板

`PasteLink_Copy_Production.unsigned.shortcut` 是未签名的候选模板，不是可直接安装或已经在真机验证的快捷指令。它保留原分享快捷指令的两步和输入连接，将 App Intent 的包名改为当前正式工程的 `com.pastelink.app`，Team Identifier 对应当前工程的签名配置。若实际安装时更换了包名或 Team，需要用实际签名的 App 在快捷指令中重新创建动作。

在有快捷指令工具的 Mac 上，可尝试按 Apple 的共享方式签名后导入：

```sh
shortcuts sign --mode anyone --input PasteLink_Copy_Production.unsigned.shortcut --output PasteLink_Copy_Production.signed.shortcut
```

签名是否接受此候选模板、导入时是否正确解析正式版动作，以及系统“复制到剪贴板”动作对文字和图片的处理，都需要在安装了正式版 App 的 Apple 设备上验证。验证成功后，可在快捷指令 App 中创建 iCloud 分享链接，并将其填入 PasteLink 的自定义复制快捷指令链接。最终仍需在 iPhone 控制中心添加系统的“快捷指令”控件并选择该快捷指令。

如果没有 Mac 或模板无法导入，可在 iPhone 的快捷指令中手动创建：依次选择 PasteLink 的“获取 Windows 最新剪贴板”和系统“复制到剪贴板”，并把前一步输出接到后一步。
