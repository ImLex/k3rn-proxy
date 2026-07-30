import Foundation
import Supabase

/// User-facing error surface for the service layer.
enum AppError: LocalizedError, Equatable {
    case duplicateUsername
    case notFound
    case permissionDenied   // silent RLS: 0 rows affected on a gated write
    case network(String)

    var errorDescription: String? {
        switch self {
        case .duplicateUsername: return "A player with this username already exists."
        case .notFound: return "Player not found."
        case .permissionDenied: return "Admin role required."
        case let .network(msg): return msg
        }
    }

    /// Map a thrown Supabase/PostgREST error to a friendly AppError.
    /// Postgres `23505` (unique violation) → duplicate username (guide §9.3).
    static func map(_ error: Error) -> AppError {
        if let pg = error as? PostgrestError {
            if pg.code == "23505" || (pg.message.contains("duplicate") && pg.message.contains("username")) {
                return .duplicateUsername
            }
            return .network(pg.message)
        }
        return .network(error.localizedDescription)
    }
}
