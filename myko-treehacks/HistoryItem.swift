//
//  HistoryItem.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/14/26.
//


import Foundation
import Combine
import UIKit

struct HistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let imagePath: String
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []

    private let metadataFileName = "history.json"

    init() {
        loadItems()
    }

    func save(image: UIImage) throws {
        guard let pngData = image.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }

        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let fileURL = historyDirectory.appendingPathComponent(fileName)
        try pngData.write(to: fileURL, options: .atomic)

        let newItem = HistoryItem(id: id, createdAt: Date(), imagePath: fileName)
        items.insert(newItem, at: 0)
        try persistMetadata()
    }

    func imageURL(for item: HistoryItem) -> URL {
        historyDirectory.appendingPathComponent(item.imagePath)
    }

    private var historyDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let historyDirectory = documents.appendingPathComponent("History", isDirectory: true)
        if !FileManager.default.fileExists(atPath: historyDirectory.path) {
            try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        }
        return historyDirectory
    }

    private var metadataURL: URL {
        historyDirectory.appendingPathComponent(metadataFileName)
    }

    private func loadItems() {
        let url = metadataURL
        guard let data = try? Data(contentsOf: url) else {
            items = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([HistoryItem].self, from: data)
            items = decoded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            items = []
        }
    }

    private func persistMetadata() throws {
        let sorted = items.sorted { $0.createdAt > $1.createdAt }
        let data = try JSONEncoder().encode(sorted)
        try data.write(to: metadataURL, options: .atomic)
        items = sorted
    }
}
