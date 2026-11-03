// Offline end-to-end replay through WaveBird's real profile, pair and output code.
import Foundation
@main struct NJ22Replay {
 static func main() async throws {
  guard CommandLine.arguments.count==2 else{print("Usage: nj22-replay CAPTURE.jsonl");exit(2)}
  let profiles:[any ControllerProfile]=[JoyConProfile(side:.left),JoyConProfile(side:.right)]
  let entries=HIDOutputCatalog.default.entries
  let sessions=entries.map{$0.makeProfile(JoyConPairProfile()).makeSession(deviceSerial:"NJ22-replay")}
  var states=[ControllerState.zero,ControllerState.zero],counts=[0,0],seen=[ButtonSet(),ButtonSet()],axisValues=[Set<Int16>(),Set<Int16>()]
  for line in try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8).split(separator:"\n") {
   let row=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
   guard row["event"] as? String=="input",let hex=row["hex"] as? String,let _=row["id"] as? String else{continue}
   guard let reportID=row["reportID"] as? Int,[7,8].contains(reportID) else{fatalError("Native capture requires reportID 7 or 8")}
   let side=reportID==7 ? 0:1
   var packet=Data();var i=hex.startIndex
   while i<hex.endIndex{let end=hex.index(i,offsetBy:2);packet.append(UInt8(hex[i..<end],radix:16)!);i=end}
   guard let state=profiles[side].parseBLEReport(packet,reportID:side==0 ? 7:8,calibration:ControllerCalibration()) else{fatalError("Rejected measured native packet")}
   guard state.imu==nil,(side==0 ? state.rightStick:state.leftStick) == .zero else{fatalError("Unexpected absent-half input")}
   states[side]=state;counts[side]+=1;seen[side].formUnion(state.buttons)
   let stick=side==0 ? state.leftStick:state.rightStick;axisValues[side].insert(stick.x);axisValues[side].insert(stick.y)
   let combined=JoyConPairProfile.merge(left:states[0],right:states[1])
   guard combined.leftStick==states[0].leftStick,combined.rightStick==states[1].rightStick else{fatalError("Pair lost a stick")}
   let pressed=combined.buttons.contains(.a)
   for (mode,session) in zip(entries,sessions) {
    let report=await session.buildReport(combined)
    let bit:Bool
    switch mode.id {
    case "switchPro":guard report.count==12,report[0]==0x3f else{fatalError("Switch report shape")};bit=report[1]&2 != 0
    case "dualShock4":guard report.count==64 else{fatalError("DS4 report shape")};bit=report[5]&0x40 != 0
    case "dualSense":guard report.count==64 else{fatalError("DualSense report shape")};bit=report[8]&0x40 != 0
    case "xboxSeries":guard report.count==17 else{fatalError("Xbox report shape")};bit=report[14]&2 != 0
    default:continue
    }
    guard bit==pressed else{fatalError("\(mode.id) lost/released physical A incorrectly")}
   }
  }
  guard counts.allSatisfy({$0>100}),axisValues.allSatisfy({$0.count>10}),seen[0].contains(.l),seen[1].contains(.a) else{fatalError("Capture lacks both pads' controls")}
  print("PASS: left=\(counts[0]) right=\(counts[1]); native decode → combined pair → Switch Pro / Xbox / DS4 / DualSense reports. Buttons, stick separation and A press/release verified.")
 }
}
