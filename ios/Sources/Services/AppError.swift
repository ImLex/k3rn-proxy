import Foundation
import Supabase

/// User-facing error surface for the service layer.
enum AppError: LocalizedError, Equatable {
    case duplicateUsername
    case notFound
    case permissionDenied   // silent RLS: 0 rows affected on a gated write
    case cancelled          // async Task cancelled (superseded load, view gone) — never a real failure
    case network(String)

    var errorDescription: String? {
        switch self {
        case .duplicateUsername: return "A player with this username already exists."
        case .notFound: return "Player not found."
        case .permissionDenied: return "Admin role required."
        case .cancelled: return nil   // nil → callers clear the banner instead of showing one
        case let .network(msg): return msg
        }
    }

    /// Map a thrown Supabase/PostgREST error to a friendly AppError.
    /// Postgres `23505` (unique violation) → duplicate username (guide §9.3).
    static func map(_ error: Error) -> AppError {
        // Already mapped upstream (a service that rethrows AppError) — pass through
        // so a cancellation stays a cancellation instead of being re-wrapped as
        // .network("…Swift.CancellationError error 1").
        if let appErr = error as? AppError { return appErr }
        // A cancelled async Task is not a user-facing failure: it happens on tab
        // switch, superseded pull-to-refresh, or a view disappearing mid-load.
        if error is CancellationError { return .cancelled }
        if let urlErr = error as? URLError, urlErr.code == .cancelled { return .cancelled }
        if let pg = error as? PostgrestError {
            if pg.code == "23505" || (pg.message.contains("duplicate") && pg.message.contains("username")) {
                return .duplicateUsername
            }
            return .network(pg.message)
        }
        return .network(error.localizedDescription)
    }
}
