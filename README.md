# 移动客户端

Flutter 移动端应用，用于用户登录、展示粉丝数据、同步设备状态，并响应后台下发的设备控制指令。

## 功能

- 使用后台导入的用户名和系统分配的 5 位数字密码登录客户端。
- 登录成功后账号自动激活，并绑定当前设备。
- 进入工作模式点击启动后开始缓慢增长粉丝，点击暂停后停止增长。
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
