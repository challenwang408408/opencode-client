//
//  ModelPreset.swift
//  OpenCodeClient
//

import Foundation

struct ModelPreset: Codable, Identifiable {
    var id: String { "\(providerID)/\(modelID)" }
    let displayName: String
    let providerID: String
    let modelID: String
    
    var shortName: String {
        if displayName.localizedCaseInsensitiveContains("Spark") { return "Spark" }
        if displayName.contains("Opus") { return "Opus" }
        if displayName.contains("Sonnet") { return "Sonnet" }
        if displayName.contains("Gemini") { return "Gemini" }
        if displayName.contains("GPT") { return "GPT" }
        if displayName.localizedCaseInsensitiveContains("GLM") { return "GLM" }
        return displayName
    }
}
