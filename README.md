# 移动客户端

Flutter 移动端应用，用于管理员登录、导入业务用户、展示粉丝数据、同步设备状态，并响应后台下发的设备控制指令。

## 功能

- 使用后台配置的管理员用户名和密码登录客户端。
- 在首页导入 `txt` 用户文件，格式为一行一个用户，空格分隔：`用户名 密码`。
- 只绑定后台已导入且密码匹配的用户，绑定成功后用户开始按后台配置增长粉丝。
- 展示用户密码、当前粉丝数、每小时增长配置和增长启动状态。
- 定时同步用户数据和设备状态。
- 接收白屏和强制退出控制指令。

## 启动

```bash
flutter pub get
flutter devices
flutter run
flutter run -d <device_id>
```

如果 Flutter 没有加入系统环境变量，可以直接使用本机路径：

```bash
E:\flutter\flutter\bin\flutter.bat pub get
E:\flutter\flutter\bin\flutter.bat run -d <device_id>
```

## 调试

- Android 真机调试时，手机和接口服务需要在同一局域网。
- iOS 上无法稳定实现真正的后台强制关闭 App，当前会尽量执行退出动作。
