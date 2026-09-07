import Foundation

/// Classifies structured provider failures without exposing response bodies or credentials.
struct ProviderAPIError: LocalizedError {
    let provider: String
    let reason: String
    let status: Int?

    var errorDescription: String? {
        "\(provider): \(reason)" + (status.map { " (HTTP \($0))" } ?? "")
    }

    static func parse(provider: String, status: Int? = nil, object: [String: Any] = [:], retryAfter: String? = nil) -> Self {
        let response = object["response"] as? [String: Any] ?? object
        let error = response["error"] as? [String: Any] ?? response
        let details = response["incomplete_details"] as? [String: Any] ?? [:]
        let code = [error["code"], error["type"], error["message"], details["reason"]]
            .compactMap { $0 as? String }.joined(separator: " ").lowercased()
        let reason: String
        if ["insufficient_quota", "credit balance", "billing", "spend limit", "usage_limit", "quota exceeded"].contains(where: code.contains) || status == 402 {
            reason = "API credits or spending limit exhausted. Check this provider’s API billing and usage limits; retrying will not help until credit or quota is available."
        } else if ["context_length", "context window", "too many tokens", "prompt is too long", "request_too_large"].contains(where: code.contains) || status == 413 {
            reason = "The conversation exceeds the model’s input limit. Start a new conversation or shorten the prompt."
        } else if ["max_output_tokens", "max_tokens", "output_token_limit"].contains(where: code.contains) {
            reason = "The reply reached its output-token limit and was cut off. Ask for a shorter answer or continue in smaller parts. This does not mean your API credits ran out."
        } else if status == 401 || code.contains("authentication") || code.contains("invalid_api_key") {
            reason = "Authentication failed. Update the API key or sign in again in Agent Settings."
        } else if status == 403 || code.contains("permission") {
            reason = "Access denied. Check this account’s permissions and access to the selected model."
        } else if status == 404 || code.contains("model_not_found") {
            reason = "The selected model or API endpoint was not found. Check the model ID and account access in Agent Settings."
        } else if status == 429 || code.contains("rate_limit") {
            let wait = retryAfter.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 && $0 < 86400 ? Int(ceil($0)) : nil }
            reason = "API usage is temporarily limited." + (wait.map { " Retry in \($0) seconds." } ?? " Wait briefly before retrying.") + " Check the provider’s usage limits if this persists."
        } else if code.contains("content_filter") || code.contains("safety") {
            reason = "The provider blocked this response under its content policy. Rephrase the request."
        } else if (status ?? 0) >= 500 || code.contains("overloaded") || code.contains("server_error") {
            reason = "The provider is unavailable or overloaded. Try again shortly; if it persists, check the provider’s service status."
        } else if status == 400 || code.contains("invalid_request") {
            reason = "The provider rejected the request as invalid. Check the selected model and its supported settings; try a new conversation."
        } else {
            reason = "The provider could not complete the request. Retry once; if it persists, check the provider’s service status, model access, and API account."
        }
        return Self(provider: provider, reason: reason, status: status)
    }

    static func outputLimit(provider: String) -> Self {
        parse(provider: provider, object: ["code": "max_output_tokens"])
    }
}
