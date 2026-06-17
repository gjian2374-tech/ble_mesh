# ble_mesh

A Flutter BLE Mesh plugin that implements real PB-GATT provisioning, Proxy connections, configuration messages, and encrypted control on **Android** and **iOS**, both built on the [Nordic nRF Mesh Library](https://www.nordicsemi.com/Products/Development-software/nRF-Mesh), with consistent behavior across platforms.

## Feature Overview

| Feature | Android | iOS | Notes |
|------|---------|-----|------|
| Initialization & permissions | ✅ | ✅ | Load/create Mesh network, request Bluetooth permissions |
| Scan unprovisioned devices | ✅ | ✅ | Advertises Mesh Provisioning Service (0x1827) |
| PB-GATT provisioning | ✅ | ✅ | Full provisioning + automatic AppKey distribution and model binding |
| Proxy connection | ✅ | ✅ | Connect to Mesh Proxy Service (0x1828) to send/receive encrypted PDUs |
| Unicast control | ✅ | ✅ | Generic On/Off, Generic Level |
| Group management | ✅ | ✅ | Create/delete groups, Subscription Add / Delete |
| Multicast control | ✅ | ✅ | Send Generic On/Off to group addresses |
| Change group | ✅ | ✅ | `changeNodeGroup`: remove old group subscription and join a new group |
| Sync Group | ✅ | ✅ | Vendor **0x0001** / **0x0002**, `configureSyncModels` / `configureSyncMaster/Slave` |
| Node deletion | ✅ | ✅ | Config Node Reset + local network sync |
| Network import/export | ✅ | ✅ | nRF Mesh App compatible JSON |
| Vendor messages | ✅ | ✅ | Espressif CID 0x02E5 master/slave switching, play mode, etc. |
| Scene management | ⚠️ Native layer | ⚠️ Local placeholder | **Not yet exposed in Dart**; Android native can send Scene messages, iOS uses local cache placeholder |
| Light Lightness | ⚠️ Native layer | ⚠️ Native layer | **Not yet exposed as a public Dart API** |

## Architecture

```
Flutter (Dart)
    │ MethodChannel / EventChannel
    ├─ Android ── Nordic nRF Mesh Library 3.3.7 (Kotlin)
    └─ iOS     ── nRFMeshProvision ~4.2.0 (Swift)
```

| Phase | Flow |
|------|------|
| **Provisioning** | PB-GATT (0x1827) → key exchange → write to Nordic Mesh DB |
| **Auto-configuration** | After Proxy is ready → `ConfigCompositionDataGet` → `ConfigAppKeyAdd` → `ConfigModelAppBind` |
| **Control** | Proxy GATT (0x1828) → Nordic encryption stack → unicast/multicast Mesh messages |
| **Grouping** | Create group → `ConfigModelSubscriptionAdd` / `Delete` → send control messages to group address |

After provisioning completes, the **native layer automatically connects to Proxy and distributes AppKey / model bindings** (actively scans for Proxy advertising instead of a fixed wait). The Dart layer should listen to `configurationState` and wait for `complete` — **do not call `distributeAppKey()` on every Proxy connection**.

## Installation

Add to `pubspec.yaml`:

```yaml
dependencies:
  ble_mesh:
    path: ../ble_mesh   # or published version number
```

After running `flutter pub get`, iOS automatically pulls in `nRFMeshProvision` via `ble_mesh.podspec`, and Android pulls in the Nordic Mesh library via `build.gradle.kts`. **No manual Podfile changes required**.

## Quick Start

### 1. Initialization

Use `initializeAndWaitForNetwork` to ensure the local Mesh DB is loaded before scanning/provisioning:

```dart
final mesh = BleMesh();

await mesh.initializeAndWaitForNetwork(
  timeout: const Duration(seconds: 10),
);

// Android must request Bluetooth permissions; iOS returns true directly,
// permissions are prompted by the system on first Bluetooth use
final granted = await mesh.requestPermissions();
if (!granted) {
  // Handle permission denial (mainly on Android)
}
```

### 2. Listen to Events

```dart
// Bluetooth on/off state
mesh.bluetoothState.listen((state) { /* ... */ });

// Scan results
mesh.scanResults.listen((device) {
  print('${device.name} uuid=${device.uuid} rssi=${device.rssi}');
});

// Provisioning progress
mesh.provisioningState.listen((state) { /* connecting / provisioning / complete / failed */ });

// New node added
mesh.nodeAdded.listen((node) {
  print('Node ${node.name} address ${node.hexAddress}');
});

// Post-provisioning configuration progress (AppKey + model binding) — wait for complete before control
mesh.configurationState.listen((status) {
  switch (status.state) {
    case MeshConfigurationState.pendingProxy:
      print('Waiting for Proxy connection…');
    case MeshConfigurationState.proxyConnected:
      print('Starting AppKey / Bind distribution…');
    case MeshConfigurationState.complete:
      print('Node ${status.unicastAddress} configured, ready for control');
    case MeshConfigurationState.failed:
      print('Configuration failed: ${status.message}');
    default:
      break;
  }
});

// Proxy connection state
mesh.connectionState.listen((state) { /* connected / disconnected */ });

// Node deletion complete
mesh.nodeDeleted.listen((unicastAddress) {
  print('Node deleted: 0x${unicastAddress.toRadixString(16)}');
});
```

### 3. Scan and Provision

```dart
await mesh.startScan(timeout: const Duration(seconds: 15));

try {
  await mesh.provisionDevice(
    uuid: device.uuid,
    address: device.address,   // Android: MAC; iOS: CBPeripheral UUID
    nodeName: 'Living Room Light',
  );
} on ProvisioningException catch (e) {
  print('Provisioning failed: ${e.message}');
}
```

> **Note**: The `address` parameter in `provisionDevice` is the **Bluetooth identifier** from scan results (`BleMeshDevice.address`), not the Mesh unicast address. The unicast address is automatically assigned by the Nordic library based on the Provisioner range (skipping addresses in the exclusion list from deleted nodes).

### 4. Post-Provisioning Auto-Configuration (AppKey + Model Binding)

After successful provisioning, the native layer will:

1. Add the node to the pending configuration queue
2. Actively scan for Proxy advertising, then connect as soon as the device is ready
3. After Proxy is ready, send Composition → AppKey Add → Model Bind

The Dart layer only needs to listen to `configurationState`:

```dart
// ✅ Recommended: wait for native auto-configuration to complete
await mesh.configurationState
    .firstWhere(
      (s) =>
          s.unicastAddress == nodeAddress &&
          s.state == MeshConfigurationState.complete,
    )
    .timeout(const Duration(seconds: 30));

// ⚠️ Use only for manual retry (e.g. tap "Redistribute" after config failure)
await mesh.distributeAppKey(nodeAddress);
```

**Notes**

- Proxy reconnection (grouping, change group, etc.) **will not** re-distribute AppKey to already configured nodes (both platforms only configure nodes in the queue or nodes with empty `applicationKeys`).
- Do not unconditionally call `distributeAppKey()` in a `connectionState == connected` callback, as it may conflict with native auto-configuration.

### 5. Connect to Proxy

Control messages require connecting to the node's **Mesh Proxy Service** first. The `connectToProxy` parameter is the **Bluetooth address**, typically `node.macAddress`:

```dart
if (node.macAddress != null) {
  final mac = node.macAddress!;
  if (!await mesh.isProxyReady(mac)) {
    await mesh.connectToProxy(mac);
  }
}
```

Use `isProxyReady(address)` to check whether the Proxy channel is fully ready (GATT connected, notifications enabled, Mesh PDUs can be sent/received) without waiting on `connectionState` events. This is useful when restoring UI after app launch or before sending control messages.

> **Note**: The native layer persists Mesh UUID → peripheral UUID mapping to `UserDefaults` (iOS) / in-memory cache (Android). After a cold start, `getNodes()` usually restores `macAddress`. If iOS cannot `retrievePeripherals` (device not discovered by this app for a long time), you need to scan again before connecting to Proxy.

### 6. Unicast Control

```dart
// Requires: Proxy connected + configurationState.complete
await mesh.sendGenericOnOff(address: 0x0002, onOff: true);
await mesh.sendGenericLevel(address: 0x0002, level: 16384);
```

### 7. Group Control

Default control group address is `kDefaultControlGroupAddress` (`0xC001`):

```dart
import 'package:ble_mesh/ble_mesh.dart';

// 1. Ensure the group exists
final group = await mesh.ensureGroup(
  name: 'Control Group',
  address: kDefaultControlGroupAddress,
);

// 2. Connect to Proxy
await mesh.connectToProxy(node.macAddress!);

// 3. Subscribe to group (AppKey already bound after provisioning; only Subscription Add here)
for (final addr in [0x0002, 0x0003]) {
  await mesh.addModelSubscription(
    nodeAddress: addr,
    modelId: kGenericOnOffModelId,
    subscriptionAddress: group.address,
  );
}

// 4. Multicast control
await mesh.sendGenericOnOff(
  address: kDefaultControlGroupAddress,
  onOff: false,
);
```

#### Change Group / Remove Subscription

```dart
// Move device from 0xC001 to 0xC002 (Delete → Add, auto-creates target group if missing)
await mesh.changeNodeGroup(
  nodeAddress: 0x0002,
  fromGroupAddress: kDefaultControlGroupAddress,
  toGroupAddress: 0xC002,
  targetGroupName: 'Backup Group',
);

// Batch change group
await mesh.changeNodesGroup(
  nodeAddresses: [0x0002, 0x0003],
  fromGroupAddress: 0xC001,
  toGroupAddress: 0xC002,
);

// Remove from current group only
await mesh.removeModelSubscription(
  nodeAddress: 0x0002,
  modelId: kGenericOnOffModelId,
  subscriptionAddress: kDefaultControlGroupAddress,
);
```

#### Model Subscription / Publication (single or combined)

Use [MeshModelMessagingMode] to explicitly select capabilities, or call lower-level APIs separately:

```dart
// Combined configuration (recommended): Bind + subscribe/publish
await mesh.configureModel(
  nodeAddress: 0x0002,
  modelId: kGenericOnOffModelId,
  groupAddress: kDefaultControlGroupAddress,
  mode: MeshModelMessagingMode.subscribeOnly, // subscribe only
);

await mesh.configureModel(
  nodeAddress: 0x0002,
  modelId: kDeviceControlModelCompoundId,
  mode: MeshModelMessagingMode.appKeyOnly, // Bind AppKey only, no groupAddress needed
);

await mesh.configureModel(
  nodeAddress: 0x0002,
  modelId: kDeviceControlModelCompoundId,
  groupAddress: kDefaultSyncGroupAddress,
  mode: MeshModelMessagingMode.publishOnly, // publish only
);

await mesh.configureModel(
  nodeAddress: 0x0002,
  modelId: kSyncModelCompoundId,
  groupAddress: kDefaultSyncGroupAddress,
  mode: MeshModelMessagingMode.subscribeAndPublish, // subscribe + publish
);

// Atomic operations (no bind needed if AppKey already bound after provisioning)
await mesh.addModelSubscription(
  nodeAddress: 0x0002,
  modelId: kGenericOnOffModelId,
  subscriptionAddress: kDefaultControlGroupAddress,
);

await mesh.setModelPublication(
  nodeAddress: 0x0002,
  modelId: kDeviceControlModelCompoundId,
  publishAddress: kDefaultSyncGroupAddress,
);

await mesh.removeModelSubscription(
  nodeAddress: 0x0002,
  modelId: kGenericOnOffModelId,
  subscriptionAddress: kDefaultControlGroupAddress,
);

await mesh.setModelPublication(
  nodeAddress: 0x0002,
  modelId: kDeviceControlModelCompoundId,
  publishAddress: 0, // clear publication
);
```

The **Example app** home page AppBar "Group Control Test" page includes: create group → subscribe → change group → multicast; the node control page includes Sync Group master/slave configuration UI.

### 8. Sync Group

The sync group (default `0xC000`) is used for firmware `send_ble_mesh_sync_mode`. Configure Vendor **0x0001** / **0x0002** flexibly via [configureSyncModels]:

| Option | Description |
|------|------|
| **Models** | Select only 0x0001, only 0x0002, or both (`modelIds`) |
| **Capabilities** | `appKeyOnly` / `subscribeOnly` / `publishOnly` / `subscribeAndPublish` |

```dart
await mesh.connectToProxy(node.macAddress!);

// Flexible configuration: both models + subscribe + publish
await mesh.configureSyncModels(
  nodeAddress: 0x0002,
  mode: MeshModelMessagingMode.subscribeAndPublish,
);

// 0x0002 publish only
await mesh.configureSyncModels(
  nodeAddress: 0x0002,
  mode: MeshModelMessagingMode.publishOnly,
  modelIds: [kDeviceControlModelCompoundId],
);

// Bind AppKey only, no subscription/publication
await mesh.configureSyncModels(
  nodeAddress: 0x0002,
  mode: MeshModelMessagingMode.appKeyOnly,
  modelIds: kSyncVendorModelCompoundIds,
);

// Shortcuts: master / slave (modelIds parameter still supported)
await mesh.configureSyncMaster(nodeAddress: 0x0002);
await mesh.configureSyncSlave(nodeAddress: 0x0003);
```

### 9. Delete Node and Re-Provision

```dart
await mesh.deleteNode(0x0002);
// Wait for nodeDeleted before re-provisioning
```

| Note | Description |
|--------|------|
| Wait for deletion to complete | Deletion sends `Config Node Reset` and disconnects GATT; listen for `nodeDeleted` |
| Automatic address assignment | Do not manually specify unicast address on re-provision; Nordic uses `nextAvailableUnicastAddress` |
| iOS GATT cleanup | PB-GATT Bearer is closed before delete/re-provision to avoid "device already in use" |
| Device-side reset | If device has reset but app still has old node, call `deleteNode` first or import a clean network |

### 10. Network Backup and Migration

```dart
final json = await mesh.exportNetworkJson();
await mesh.importNetworkJson(json);
// Triggers networkLoaded / networkUpdated
```

Format is compatible with the nRF Mesh App Mesh Configuration Database.

### 11. Vendor Device Control (Espressif)

```dart
await mesh.setMasterSlaveRole(address: 0x0002, role: MeshNodeRole.master);

await mesh.setPlayMode(
  address: 0x0002,
  config: PlayModeConfig(
    sourceType: SourceType.sdCard,
    modeIndex: 1,
    speed: 5,
    brightness: 32768,
  ),
);

mesh.vendorMessages.listen((status) {
  print('Vendor ${status.hexSource} op=0x${status.opCode.toRadixString(16)}');
});
```

| Constant | Value | Purpose |
|------|-----|------|
| `kVendorCompanyId` | `0x02E5` | Espressif CID |
| `kDefaultSyncGroupAddress` | `0xC000` | Sync multicast address |
| `kDefaultControlGroupAddress` | `0xC001` | Default control group |
| `kGenericOnOffModelId` | `0x1000` | SIG Generic OnOff Server |

## Complete Workflow

```
initializeAndWaitForNetwork
        ↓
   startScan → provisionDevice
        ↓
  Native auto-connects Proxy (active scan, typically ~0.5–2s)
        ↓
 configurationState.complete (AppKey + Model Bind)
        ↓
 connectToProxy (if not already connected)
        ↓
 Unicast control / ensureGroup → addModelSubscription → multicast
        ↓
 changeNodeGroup (optional: move to another group)
```

## Error Handling

All exceptions inherit from `BleMeshException`:

```dart
try {
  await mesh.sendGenericOnOff(address: 0x0002, onOff: true);
} on NotInitializedException {
  // initialize() not called
} on NotConnectedException {
  // Proxy not connected
} on BluetoothDisabledException {
  // Bluetooth is off
} on PermissionDeniedException {
  // Permission denied
} on ProvisioningException catch (e) {
  // Provisioning failed
} on BleMeshException catch (e) {
  print('[${e.code}] ${e.message}');
}
```

## Debugging

### Xcode (iOS)

Filter Console by `BleMesh` or the following tags:

| Tag | Meaning |
|------|------|
| `[PROVISION]` | Provisioning and address assignment |
| `[DELETE]` | Node deletion and reset |
| `[GROUP]` | AppKey / Bind / Subscription Add·Delete |
| `[PROXY]` | Proxy connection and PDU |
| `[NET]` / `[CACHE]` | Network DB and cache |

**Successful AppKey configuration** should show:

```
─── Starting AppKey distribution to node 0x0002 ───
Composition Data retrieved, models to bind=4
Sending ConfigAppKeyAdd → 0x0002
Binding SIG Model 0x1000 @0x0002
Binding SIG Model 0x1002 @0x0002
Binding Vendor Model CID=0x02E5 Model=0x0001 @0x0002
Binding Vendor Model CID=0x02E5 Model=0x0002 @0x0002
─── AppKey distribution sequence complete ───
```

**Successful group subscription** should show:

```
[GROUP] Sending ConfigModelSubscriptionAdd ... group=0xC001
[GROUP] ConfigModelSubscriptionAdd succeeded
```

**Successful group change** should show:

```
[GROUP] Sending ConfigModelSubscriptionDelete ... group=0xC001
[GROUP] ConfigModelSubscriptionDelete succeeded
[GROUP] Sending ConfigModelSubscriptionAdd ... group=0xC002
```

Device serial output (ESP, etc.) corresponds to: `MODEL_OP_APPKEY_ADD`, `MODEL_OP_MODEL_APP_BIND`, `MODEL_OP_MODEL_SUB_ADD` / `MODEL_OP_MODEL_SUB_DELETE`; for group control, `dst 0xc001`.

### Android

Filter Logcat by `BleMesh` or `BleMeshNetworkManager`.

### Example App

```bash
cd example && flutter run
```

The home page includes device list, unicast/Vendor control, and a debug log panel; the AppBar group icon opens the group/change-group test page.

## Platform Configuration

### Android

`AndroidManifest.xml` must include (usually merged by the plugin):

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

Dependency: `no.nordicsemi.android:mesh:3.3.7` (see `android/build.gradle.kts`).

### iOS

Add Bluetooth usage descriptions to `Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Bluetooth permission is required to control Mesh lighting devices</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Bluetooth permission is required to control Mesh lighting devices</string>
```

Dependency: `nRFMeshProvision ~> 4.2.0` (see `ios/ble_mesh.podspec`).

Minimum system version: **iOS 13.0**.

## Dart API Reference

### Main Methods

| Method | Description |
|------|------|
| `initialize()` / `initializeAndWaitForNetwork()` | Initialize and load Mesh network |
| `startScan()` / `stopScan()` | Scan for unprovisioned devices |
| `provisionDevice()` / `cancelProvisioning()` | Provisioning |
| `connectToProxy()` / `disconnectFromProxy()` | Proxy connection (Bluetooth address string) |
| `getConnectionState()` | Query current Proxy connection state (no event stream needed) |
| `isProxyReady()` | Check if Proxy for a given Bluetooth address is ready (notifications on, PDUs can flow) |
| `distributeAppKey()` | Manually trigger AppKey configuration (for retry on failure) |
| `sendGenericOnOff()` / `sendGenericLevel()` | SIG model control |
| `getNodes()` / `deleteNode()` | Node management |
| `createGroup()` / `deleteGroup()` / `ensureGroup()` | Group management |
| `addModelSubscription()` / `removeModelSubscription()` | Subscription Add / Delete |
| `setModelPublication()` | Publication Set (`publishAddress: 0` clears publication) |
| `configureModel()` | Bind + configure subscription/publication per `MeshModelMessagingMode` |
| `changeNodeGroup()` / `changeNodesGroup()` | Change group (Delete + Add, subscription only) |
| `configureSyncModels()` | Flexible Vendor 0x0001/0x0002 configuration (models + subscribe/publish/AppKey) |
| `configureSyncMaster()` / `configureSyncSlave()` | Sync master/slave shortcut configuration |
| `configureDefaultSyncSlave()` / `promoteSyncModelToMaster()` / `demoteSyncModelToSlave()` | Sync role switching helpers |
| `getNodeByAddress()` / `getNodeByUuid()` / `getGroupByAddress()` | Node and group queries |
| `exportNetworkJson()` / `importNetworkJson()` | Network backup |
| `sendVendorMessage()` / `setMasterSlaveRole()` / `setPlayMode()` | Vendor control |

### Main Event Streams

| Stream | Description |
|----|------|
| `scanResults` | Unprovisioned devices found during scan |
| `provisioningState` | Provisioning state |
| `nodeAdded` | New node added |
| `configurationState` | Post-provisioning AppKey / Bind progress (**must listen before control**) |
| `connectionState` | Proxy connection state |
| `nodeDeleted` | Node deletion complete |
| `networkLoaded` / `networkUpdated` | Network loaded/changed |
| `meshMessages` / `vendorMessages` | Received status messages |

### configurationState States

Common states are listed below; see the full `MeshConfigurationState` enum for granular states such as `compositionGetting`, `appKeyAdding`, `modelBinding`, etc.

| State | Meaning |
|------|------|
| `pendingProxy` | Provisioning complete, waiting for Proxy |
| `proxyConnected` | Proxy connected, sending configuration messages |
| `complete` | AppKey + model binding complete |
| `failed` | Configuration failed (see `message`) |

## Data Models

| Type | Description |
|------|------|
| `BleMeshDevice` | Unprovisioned device from scan |
| `MeshNode` | Provisioned node (includes `unicastAddress`, `macAddress`, element list) |
| `MeshElement` | Node element |
| `MeshGroup` | Group (multicast address) |
| `MeshNetworkInfo` | Network summary (NetKey, AppKey, IV Index, etc.) |
| `MeshConfigurationStatus` | Configuration phase status |
| `MeshMessageStatus` | SIG model status response |
| `VendorMessageStatus` | Vendor model status response |

## Common Mesh Model IDs

| Model | ID |
|------|-----|
| Generic On/Off Server | `0x1000` |
| Generic On/Off Client | `0x1001` |
| Generic Level Server | `0x1002` |
| Generic Level Client | `0x1003` |
| Light Lightness Server | `0x1300` |
| Scene Server | `0x1203` |

## Common Mesh Address Ranges

| Range | Purpose |
|------|------|
| `0x0001 – 0x7FFF` | Unicast addresses (Provisioner typically uses `0x0001`) |
| `0xC000 – 0xFEFF` | Group addresses |
| `0xFF00 – 0xFFFF` | Fixed group addresses (e.g. `0xFFFF` for all nodes) |

## Known Limitations

- **Scene API**: Dart layer does not yet expose `getScenes` / `storeScene` and similar methods; Android native can send Scene Mesh messages, iOS uses local cache placeholder.
- **Light Lightness**: Implemented natively (iOS maps to Generic Level), but Dart layer does not yet expose `sendLightLightness`.
- **`macAddress` recovery**: Usually restored from persisted mapping after cold start; if the system cannot retrieve the peripheral, re-scan is required.
- **Manual Proxy Filter API**: Dart layer does not yet expose `setProxyFilterType` and similar interfaces; iOS internally uses Nordic Proxy Filter during auto-configuration.
- **Multiple Proxy nodes**: Only one Proxy GATT connection is maintained at a time; multicast is forwarded through the current Proxy.

## License

MIT License
