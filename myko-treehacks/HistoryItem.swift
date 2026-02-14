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
    var title: String

        init(id: UUID, createdAt: Date, imagePath: String, title: String = "Microscope Capture") {
            self.id = id
            self.createdAt = createdAt
            self.imagePath = imagePath
            self.title = title
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case createdAt
            case imagePath
            case title
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            imagePath = try container.decode(String.self, forKey: .imagePath)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Microscope Capture"
        }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []

    private let metadataFileName = "history.json"

    init() {
        loadItems()
    }

    func save(image: UIImage, title: String = "Microscope Capture") throws {
        guard let pngData = image.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }

        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let fileURL = historyDirectory.appendingPathComponent(fileName)
        try pngData.write(to: fileURL, options: .atomic)

        let newItem = HistoryItem(id: id, createdAt: Date(), imagePath: fileName, title: title)
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
