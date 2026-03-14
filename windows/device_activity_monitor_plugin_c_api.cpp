#include "include/device_activity_monitor/device_activity_monitor_plugin.h"
#include "device_activity_monitor_plugin.h"

void DeviceActivityMonitorPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  device_activity_monitor::DeviceActivityMonitorPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}