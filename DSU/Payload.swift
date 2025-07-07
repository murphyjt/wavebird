import Foundation

protocol Payload {
    /// Number of bytes when written as Data
    var count: Int {
        get
    }
    func data(using data: Data) -> Data
}
