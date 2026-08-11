#!/usr/bin/env swift

import AppKit
import Foundation
import Vision

private let expectedSidebarLabels = [
    "Dashboard",
    "All Tasks",
    "Downloading",
    "Waiting",
    "Completed",
    "Failed",
    "History",
]

guard CommandLine.arguments.count == 2 else {
    fputs("usage: check_sidebar_layout.swift <screenshot>\n", stderr)
    exit(2)
}

let screenshotPath = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: screenshotPath),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("FAIL: could not read screenshot at \(screenshotPath)\n", stderr)
    exit(2)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false

do {
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
} catch {
    fputs("FAIL: Vision text recognition failed: \(error.localizedDescription)\n", stderr)
    exit(2)
}

let sidebarTexts = (request.results ?? []).compactMap { observation -> String? in
    guard observation.boundingBox.midX < 0.20 else { return nil }
    return observation.topCandidates(1).first?.string
}

let normalizedSidebarTexts = sidebarTexts.map {
    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
let visibleLabels = expectedSidebarLabels.filter { expected in
    normalizedSidebarTexts.contains { recognized in
        recognized.hasSuffix(expected.lowercased())
    }
}

guard visibleLabels.count >= 5 else {
    let recognized = sidebarTexts.isEmpty ? "none" : sidebarTexts.joined(separator: " | ")
    fputs(
        "FAIL: sidebar labels are clipped; expected at least 5 complete labels, found "
            + "\(visibleLabels.count). Recognized in sidebar: \(recognized)\n",
        stderr
    )
    exit(1)
}

print("PASS: \(visibleLabels.count) complete sidebar labels are visible: \(visibleLabels.joined(separator: ", "))")
