import Foundation

// Per-output-mode control catalogs. Each entry mirrors exactly one read in
// that mode's encoder (file:line references in the mapping-profiles plan);
// the catalog is simultaneously the profile editor's row list and the
// pre-encode rewrite's spec. DEBUG-only passthrough modes have no catalog —
// they bypass buildReport, so mapping cannot apply.
enum MappingControls {

    static func controls(forModeID id: String) -> [OutputControl] {
        table[id] ?? []
    }

    // Nintendo-label source for each diamond face control, per output mode whose
    // diamond differs from Nintendo's. Empty for modes that are already identity
    // (switchPro) or opted out (PlayStation). Used to inject by-label defaults
    // when a profile's useNintendoLayout is on.
    static func nintendoLayoutSources(forModeID id: String) -> [String: MappingSource] {
        nintendoLayout[id] ?? [:]
    }

    private static let nintendoLayout: [String: [String: MappingSource]] = [
        "xboxSeries": [
            "xboxSeries.a": .button(.a),
            "xboxSeries.b": .button(.b),
            "xboxSeries.x": .button(.x),
            "xboxSeries.y": .button(.y),
        ],
    ]

    private static let table: [String: [OutputControl]] = [
        "xboxSeries": [
            OutputControl(id: "xboxSeries.a",            displayName: "A Button",         driver: .buttons(.b)),
            OutputControl(id: "xboxSeries.b",            displayName: "B Button",         driver: .buttons(.a)),
            OutputControl(id: "xboxSeries.x",            displayName: "X Button",         driver: .buttons(.y)),
            OutputControl(id: "xboxSeries.y",            displayName: "Y Button",         driver: .buttons(.x)),
            OutputControl(id: "xboxSeries.leftBumper",   displayName: "Left Bumper",      driver: .leftBumper),
            OutputControl(id: "xboxSeries.rightBumper",  displayName: "Right Bumper",     driver: .rightBumper),
            OutputControl(id: "xboxSeries.leftTrigger",  displayName: "Left Trigger",     driver: .leftTrigger),
            OutputControl(id: "xboxSeries.rightTrigger", displayName: "Right Trigger",    driver: .rightTrigger),
            OutputControl(id: "xboxSeries.l3",           displayName: "Left Stick Click", driver: .buttons(.stickL)),
            OutputControl(id: "xboxSeries.r3",           displayName: "Right Stick Click", driver: .buttons(.stickR)),
            OutputControl(id: "xboxSeries.view",         displayName: "View Button",      driver: .buttons(.minus)),
            OutputControl(id: "xboxSeries.menu",         displayName: "Menu Button",      driver: .buttons([.plus, .start])),
            OutputControl(id: "xboxSeries.share",        displayName: "Share Button",     driver: .buttons(.capture)),
            OutputControl(id: "xboxSeries.guide",        displayName: "Guide Button",     driver: .buttons(.home)),
        ],
        "dualShock4": [
            OutputControl(id: "dualShock4.cross",    displayName: "Cross",            driver: .buttons(.b)),
            OutputControl(id: "dualShock4.circle",   displayName: "Circle",           driver: .buttons(.a)),
            OutputControl(id: "dualShock4.square",   displayName: "Square",           driver: .buttons(.y)),
            OutputControl(id: "dualShock4.triangle", displayName: "Triangle",         driver: .buttons(.x)),
            OutputControl(id: "dualShock4.l1",       displayName: "L1",               driver: .leftBumper),
            OutputControl(id: "dualShock4.r1",       displayName: "R1",               driver: .rightBumper),
            OutputControl(id: "dualShock4.l2",       displayName: "L2",               driver: .leftTrigger),
            OutputControl(id: "dualShock4.r2",       displayName: "R2",               driver: .rightTrigger),
            OutputControl(id: "dualShock4.share",    displayName: "Share",            driver: .buttons([.capture, .minus])),
            OutputControl(id: "dualShock4.options",  displayName: "Options",          driver: .buttons([.start, .plus])),
            OutputControl(id: "dualShock4.l3",       displayName: "L3",               driver: .buttons(.stickL)),
            OutputControl(id: "dualShock4.r3",       displayName: "R3",               driver: .buttons(.stickR)),
            OutputControl(id: "dualShock4.ps",       displayName: "PS Button",        driver: .buttons(.home)),
            OutputControl(id: "dualShock4.touchpad", displayName: "Touchpad Click",   driver: .buttons(.c)),
        ],
        "dualSense": [
            OutputControl(id: "dualSense.cross",    displayName: "Cross Button",      driver: .buttons(.b)),
            OutputControl(id: "dualSense.circle",   displayName: "Circle Button",     driver: .buttons(.a)),
            OutputControl(id: "dualSense.square",   displayName: "Square Button",     driver: .buttons(.y)),
            OutputControl(id: "dualSense.triangle", displayName: "Triangle Button",   driver: .buttons(.x)),
            OutputControl(id: "dualSense.l1",       displayName: "L1 Button",         driver: .leftBumper),
            OutputControl(id: "dualSense.r1",       displayName: "R1 Button",         driver: .rightBumper),
            OutputControl(id: "dualSense.l2",       displayName: "L2 Button",         driver: .leftTrigger),
            OutputControl(id: "dualSense.r2",       displayName: "R2 Button",         driver: .rightTrigger),
            OutputControl(id: "dualSense.l3",       displayName: "L3 Button",         driver: .buttons(.stickL)),
            OutputControl(id: "dualSense.r3",       displayName: "R3 Button",         driver: .buttons(.stickR)),
            OutputControl(id: "dualSense.touchpad", displayName: "Touchpad Button",   driver: .buttons(.c)),
            OutputControl(id: "dualSense.create",   displayName: "Create Button",     driver: .buttons([.capture, .minus])),
            OutputControl(id: "dualSense.options",  displayName: "Options Button",    driver: .buttons([.start, .plus])),
            OutputControl(id: "dualSense.ps",       displayName: "PS Button",         driver: .buttons(.home)),
        ],
        "switchPro": [
            OutputControl(id: "switchPro.a",       displayName: "A Button",          driver: .buttons(.a)),
            OutputControl(id: "switchPro.b",       displayName: "B Button",          driver: .buttons(.b)),
            OutputControl(id: "switchPro.x",       displayName: "X Button",          driver: .buttons(.x)),
            OutputControl(id: "switchPro.y",       displayName: "Y Button",          driver: .buttons(.y)),
            OutputControl(id: "switchPro.l",       displayName: "L Button",          driver: .leftBumper),
            OutputControl(id: "switchPro.r",       displayName: "R Button",          driver: .rightBumper),
            OutputControl(id: "switchPro.zl",      displayName: "ZL Button",         driver: .leftTrigger),
            OutputControl(id: "switchPro.zr",      displayName: "ZR Button",         driver: .rightTrigger),
            OutputControl(id: "switchPro.l3",      displayName: "Left Stick Click",  driver: .buttons(.stickL)),
            OutputControl(id: "switchPro.r3",      displayName: "Right Stick Click", driver: .buttons(.stickR)),
            OutputControl(id: "switchPro.minus",   displayName: "Minus Button",      driver: .buttons(.minus)),
            OutputControl(id: "switchPro.plus",    displayName: "Plus Button",       driver: .buttons([.plus, .start])),
            OutputControl(id: "switchPro.capture", displayName: "Capture Button",    driver: .buttons(.capture)),
            OutputControl(id: "switchPro.home",    displayName: "Home Button",       driver: .buttons(.home)),
        ],
    ]
}
