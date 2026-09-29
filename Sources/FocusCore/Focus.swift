import Foundation
import SQLite3

public enum Focus {
    public static let version = "0.0.1"

    /// Version of the system SQLite library, confirming the raw C API links.
    public static var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }
}
