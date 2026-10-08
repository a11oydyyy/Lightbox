# 可选插件

Lightbox 原生应用不包含图片分析实现。未安装插件时，预览中不会出现图片分析按钮。

## 安装图片分析

从 [Releases](https://github.com/a11oydyyy/Lightbox/releases/latest) 下载 `Lightbox-ImageAnalysis-v1.0.0.lightboxplugin.zip` 并解压。当前图片分析插件需要 Apple Silicon 和 macOS 27 或更新版本。开发者也可运行 `./script/build_image_analysis_plugin.sh` 生成相同插件包。
在 Lightbox 的“插件 → 安装插件…”中选择这个插件包。选中图片后，可从插件菜单启动；预览顶部也会显示对应按钮。

插件在独立进程中运行，只分析传入的图片。识别文字使用 Vision；描述与标签使用 macOS 27 的本地 Apple 智能模型。系统模型不可用时，文字识别仍可使用。

正式版的插件目录为 `~/Library/Application Support/Lightbox/Plugins`，测试版使用自己的独立目录。通过“打开插件文件夹…”可管理安装内容，移走插件包后返回 Lightbox 即会刷新菜单。

原来的分析记录继续保存在宿主数据目录的 `ImageAnalysis/results.json`，升级与移走插件不删除分析记录。

## 插件协议 1

`.lightboxplugin` 是目录包，包含 `manifest.json` 和独立 `.app`：

```json
{
  "apiVersion": 1,
  "identifier": "io.github.a11oydyyy.Lightbox.ImageAnalysis",
  "name": "图片分析",
  "version": "1.0.0",
  "application": "图片分析.app",
  "symbol": "sparkles"
}
```

`identifier` 必须与内部应用的 Bundle ID 相同，`application` 必须位于插件包内，`symbol` 是可选的 SF Symbol。宿主不加载插件代码；通过 NSWorkspace 传入选中的文件 URL，并以 `--host-support-directory <路径>` 提供宿主数据目录。插件使用 NSApplicationDelegate 的 `application(_:open:)` 接收文件，关闭最后一个窗口后退出。

原生构建脚本只构建 `LightboxNative` 产品，不打包或安装插件。插件是单独的构建产品和测试目标：

```sh
swift test --filter 'plugins|imageAnalysis'
```
