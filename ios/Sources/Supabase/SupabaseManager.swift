import Foundation
import Supabase

/// Shared Supabase client (Auth + PostgREST + RPC).
enum SupabaseManager {
    static let client = SupabaseClient(
        supabaseURL: AppConfig.supabaseURL,
        supabaseKey: AppConfig.supabaseAnonKey
    )
}
