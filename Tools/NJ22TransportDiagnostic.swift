// Runs WaveBird's real BLETransport with its Nintendo commands and NJ22 fallback.
// No virtual HID, firmware update or persistent pairing operations.
import Foundation
import CoreBluetooth
@main struct NJ22TransportDiagnostic {
 static func log(_ event:String,_ fields:[String:Any]=[:]) {var r=fields;r["event"]=event;r["uptime"]=ProcessInfo.processInfo.systemUptime;if let d=try? JSONSerialization.data(withJSONObject:r,options:.sortedKeys){print(String(decoding:d,as:UTF8.self));fflush(stdout)}}
 static func hex(_ d:Data)->String{d.map{String(format:"%02x",$0)}.joined()}
 static func main() async {
  let transport=BLETransport()
  let features:NS2Feature=[.buttons,.analog]
  let matchers:[TransportMatcher]=[(UInt16(0x2066),NS2ControllerType.joyConR),(UInt16(0x2067),NS2ControllerType.joyConL)].map{pid,side in
   .ble(BLEMatcher(productID:pid,serviceUUID:CBUUID(string:"AB7DE9BE-89FE-49AD-828F-118F09DF7FD0"),inputCharacteristic:CBUUID(string:"AB7DE9BE-89FE-49AD-828F-118F09DF7FD2"),outputCharacteristic:NS2Handle.uuid(NS2Handle.commandWriteShared,for:side),responseCharacteristics:[NS2Handle.commandResponse1,NS2Handle.commandResponse2].compactMap{h in NS2Handle.uuid(h,for:side).map{ResponseChannel(uuid:$0,handle:h)}},initCommands:[NS2Commands.handshake,NS2Commands.firmwareInfo,NS2Commands.player1LED,NS2Commands.setFeatureMask(features),NS2Commands.setInputReportFormat05,NS2Commands.enableFeatures(features)],vibrationCharacteristic:NS2Handle.uuid(0x12,for:side),fallbackOutputCharacteristic:NS2Handle.uuid(NS2Handle.commandWrite,for:side),fallbackCommandPrefix:Data(repeating:0,count:17),consoleFallback:NS2Handle.uuid(NS2Handle.inputReportVariant,for:side).map{BLEConsoleFallback(inputCharacteristic:$0,inputReportID:pid==0x2067 ? 7:8)}))
  }
  await transport.startDiscovery(matchers:matchers)
  Task {try? await Task.sleep(for:.seconds(120));await transport.stopDiscovery();log("finished");exit(0)}
  var connecting=Set<DeviceID>()
  for await event in transport.events {
   switch event {
   case .discovered(let id,let info): if connecting.insert(id).inserted {log("discovered",["id":id.raw.uuidString,"pid":info.productID]);try? await transport.connect(id)}
   case .commandResponse(let id,let request,let response):log("commandResponse",["id":id.raw.uuidString,"command":hex(request),"response":response.map{hex($0.data)} ?? "none"])
   case .ready(let id):log("ready",["id":id.raw.uuidString])
   case .reportReceived(let id,let reportID,let data):log("input",["id":id.raw.uuidString,"reportID":reportID.map{Int($0)} ?? -1,"length":data.count,"hex":hex(data)])
   case .initializationFailed(let id,let reason):log("initializationFailed",["id":id.raw.uuidString,"reason":reason])
   case .disconnected(let id,let reason):log("disconnected",["id":id.raw.uuidString,"reason":String(describing:reason)])
   case .unmatchedResponse(let id,let data,_):log("unmatched",["id":id.raw.uuidString,"hex":hex(data)])
   case .error(_,let msg):log("error",["message":msg])
   default:break
   }
  }
 }
}
