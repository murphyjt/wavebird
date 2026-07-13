import Foundation
import os

// The Nintendo-side vocabulary a mapping profile's dropdown draws from — the
// union of every supported controller's physical buttons. A profile row
// sourced from a button the connected controller lacks simply never fires.
// Raw values are the persistence format (MappingProfile JSON): never rename.
enum PhysicalButton: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case a, b, x, y
    case l, r, zl, zr
    case plus, minus, home, capture
    case stickL, stickR
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case c
    case gl, gr          // NS2 Pro rear grips
    case z, start        // GameCube
    case sl, sr          // Joy-Con side rails

    var id: String { rawValue }

    // The parsed ButtonSet member that reports this button's press. Note GC's
    // L/R are analog clicks — reading the ButtonSet member means "full click".
    var buttonSetMember: ButtonSet {
        switch self {
        case .a: .a
        case .b: .b
        case .x: .x
        case .y: .y
        case .l: .l
        case .r: .r
        case .zl: .zl
        case .zr: .zr
        case .plus: .plus
        case .minus: .minus
        case .home: .home
        case .capture: .capture
        case .stickL: .stickL
        case .stickR: .stickR
        case .dpadUp: .dpadUp
        case .dpadDown: .dpadDown
        case .dpadLeft: .dpadLeft
        case .dpadRight: .dpadRight
        case .c: .c
        case .gl: .gl
        case .gr: .gr
        case .z: .z
        case .start: .start
        case .sl: .sl
        case .sr: .sr
        }
    }

    // Editor dropdown grouping.
    enum Family: String, CaseIterable, Identifiable {
        case common = "Common"
        case pro = "Pro Controller"
        case gameCube = "GameCube"
        case joyCon = "Joy-Con"
        var id: String { rawValue }
    }

    var family: Family {
        switch self {
        case .gl, .gr: .pro
        case .z, .start: .gameCube
        case .sl, .sr: .joyCon
        default: .common
        }
    }

    var displayName: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .l: "L"
        case .r: "R"
        case .zl: "ZL"
        case .zr: "ZR"
        case .plus: "Plus"
        case .minus: "Minus"
        case .home: "Home"
        case .capture: "Capture"
        case .stickL: "Left Stick Click"
        case .stickR: "Right Stick Click"
        case .dpadUp: "D-pad Up"
        case .dpadDown: "D-pad Down"
        case .dpadLeft: "D-pad Left"
        case .dpadRight: "D-pad Right"
        case .c: "C"
        case .gl: "GL"
        case .gr: "GR"
        case .z: "Z"
        case .start: "Start"
        case .sl: "SL"
        case .sr: "SR"
        }
    }
}

// One row's stored choice in a MappingProfile: drive the control from a
// physical button, or disable it outright. Absence from the dict = Default.
enum MappingChoice: RawRepresentable, Codable, Sendable, Hashable {
    case off
    case physical(PhysicalButton)

    var rawValue: String {
        switch self {
        case .off: "off"
        case .physical(let button): button.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue == "off" {
            self = .off
        } else if let button = PhysicalButton(rawValue: rawValue) {
            self = .physical(button)
        } else {
            return nil
        }
    }
}
