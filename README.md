# Edu Whiteboard iOS

一款面向教学场景的原生 iOS 白板应用。按住说话即可将讲解内容转成文本卡片，并在自由画布上完成拖拽、缩放、高亮与擦除，适合课堂讲解、题目分析和板书整理。

## 产品用途

- 将口述内容快速转写为白板文本
- 在自由画布上移动、缩放和整理文本卡片
- 通过高亮与橡皮擦突出重点、清理内容
- 适用于教师授课、备课演示和知识点拆解

## 可运行的平台

- iPhone / iPad
- iOS 26.4 及以上
- iOS Simulator 可用于构建和界面调试

说明：本地语音转写依赖系统 Speech 能力，建议在支持该能力的真机上体验完整流程。

## 开发构建

使用 Xcode 打开 `EduWhiteBoardiOS.xcodeproj`，或在仓库根目录执行：

```bash
xcodebuild -project EduWhiteBoardiOS.xcodeproj -scheme EduWhiteBoardiOS -destination 'generic/platform=iOS Simulator' build
```

## 开源致谢

本仓库在产品原型探索和资源使用上受益于以下开源项目与社区：

- 应用内使用的字体资源 [Ma Shan Zheng](https://github.com/googlefonts/mashanzheng) 与 [Shantell Sans](https://github.com/arrowtype/shantell-sans)

## License

本项目源码基于 [MIT License](./LICENSE) 开源。

补充说明：

- `EduWhiteBoardiOS/Fonts` 目录下的字体文件继续遵循各自的 SIL Open Font License 1.1